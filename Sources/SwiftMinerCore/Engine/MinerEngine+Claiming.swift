import Foundation

// Claiming ready drops, and the heuristics that keep Twitch's internal test campaigns from
// being mistaken for real progress.
//
// Split out of MinerEngine.swift, which had grown past the point where one file could be read.

/// Keeps accepted-but-unconfirmed claims bounded across restarts. Confirmation and
/// notification history is scoped to the account and the exact Twitch drop instance.
struct RepeatClaimGuard {
    static let maxAcceptedClaims = 2

    private struct Entry: Codable {
        var attempts = 0
        var reportedClaim = false
        var progress: Progress?
        var accountConnected: Bool?
    }

    private var entries: [String: Entry] = [:]
    private var reportedSuppressed: Set<String> = []
    private var inFlight: Set<String> = []
    private let fileURL: URL?

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            entries = try JSONDecoder().decode([String: Entry].self, from: Data(contentsOf: fileURL))
        } catch {
            Logger.storage.error("Could not load claim history: \(error.localizedDescription)")
        }
    }

    static func fileURL(accountId: String) -> URL {
        // Account IDs are identities, never arbitrary paths.
        let filename = Data(accountId.utf8).map { String(format: "%02x", $0) }.joined()
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.swiftminer/claim-history", isDirectory: true)
            .appendingPathComponent("\(filename).json")
    }

    func isSuppressed(_ instanceId: String) -> Bool {
        guard let entry = entries[instanceId] else { return false }
        return entry.reportedClaim || entry.attempts >= Self.maxAcceptedClaims
    }

    mutating func beginClaim(_ instanceId: String) -> Bool {
        !isSuppressed(instanceId) && inFlight.insert(instanceId).inserted
    }

    mutating func endClaim(_ instanceId: String) {
        inFlight.remove(instanceId)
    }

    mutating func recordAcceptedClaim(_ instanceId: String, progress: Progress? = nil, accountConnected: Bool? = nil) {
        var entry = entries[instanceId] ?? Entry()
        entry.attempts += 1
        if let progress { entry.progress = progress }
        if let accountConnected { entry.accountConnected = accountConnected }
        entries[instanceId] = entry
        persist()
    }

    /// Linking the game repairs the original failure. Allow another bounded attempt
    /// without forgetting that a confirmed reward was already reported.
    mutating func allowRetryAfterLinking(_ instanceId: String, accountConnected: Bool?) {
        guard accountConnected == true, var entry = entries[instanceId],
              entry.accountConnected == false else { return }
        entry.attempts = 0
        entry.accountConnected = true
        entries[instanceId] = entry
        reportedSuppressed.remove(instanceId)
        persist()
    }

    var pendingClaims: [Progress] {
        entries.values.filter { !$0.reportedClaim }.compactMap(\.progress)
    }

    mutating func markClaimReported(_ progress: Progress) -> Bool {
        var entry = entries[progress.id] ?? Entry()
        guard !entry.reportedClaim else { return false }
        entry.reportedClaim = true
        entry.progress = progress
        entries[progress.id] = entry
        // Persist before callbacks: a second transport or a restart must not notify again.
        persist()
        return true
    }

    mutating func markReported(_ instanceId: String) -> Bool {
        reportedSuppressed.insert(instanceId).inserted
    }

    private func persist() {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(entries).write(to: fileURL, options: .atomic)
        } catch {
            Logger.storage.error("Could not save claim history: \(error.localizedDescription)")
        }
    }
}

extension MinerEngine {
    func claimReadyDrops(forceInventoryRefresh: Bool = false) async -> Bool {
        configureClaimHistory()
        let nowTick = runtimeClock.nowNanoseconds()
        guard Self.shouldRefreshClaimInventory(
            lastCheck: lastClaimInventoryCheckTick,
            now: nowTick,
            interval: claimCheckInterval,
            forced: forceInventoryRefresh
        ) else {
            return false
        }
        // Stamp before the await. Actor reentrancy must not let another rescan start the same
        // forced inventory request while this one is in flight. A failed read is retried on the
        // normal two-minute cadence rather than on every unrelated channel event.
        lastClaimInventoryCheckTick = nowTick

        // Always ask inventory for claimable drops. Twitch can expose a ready claim there
        // after the campaign disappears from dashboard data or local campaign state.
        var didClaimAnyDrop = false
        do {
            let inventoryService = await dropsService.getInventoryService()
            let snapshot = try await inventoryService.fetchInventory(forceRefresh: true)
            onOperationalEvent?(.successfulPoll)
            onOperationalEvent?(.inventoryRefresh)
            syncCampaigns(with: snapshot)
            await confirmPendingClaims(in: snapshot)
            for progress in snapshot.progress {
                repeatClaimGuard.allowRetryAfterLinking(
                    progress.id,
                    accountConnected: allCampaigns.first { $0.id == progress.campaignId }?.isAccountConnected
                )
            }

            let claimedDropIds = Set(
                allCampaigns
                    .flatMap(\.drops)
                    .filter(\.isClaimed)
                    .map(\.id)
            )
            let candidates = snapshot.progress.filter {
                $0.isComplete
                    && !$0.isClaimed
                    && !claimedDropIds.contains($0.dropId)
                    && !isLikelyInternalTestProgress($0)
            }
            let claimable = candidates.filter { !repeatClaimGuard.isSuppressed($0.id) }
            let newlySuppressed = candidates.filter {
                repeatClaimGuard.isSuppressed($0.id) && repeatClaimGuard.markReported($0.id)
            }
            if !newlySuppressed.isEmpty {
                let names = newlySuppressed.map(\.dropName).joined(separator: ", ")
                let linkHint = newlySuppressed.contains { progress in
                    allCampaigns.first(where: { $0.id == progress.campaignId })?.isAccountConnected == false
                } ? " The account does not appear to be linked to the game." : ""
                log("Warning: Twitch accepted the claim for \(names) but inventory still lists it as unclaimed.\(linkHint) Not retrying it again unless the game account becomes linked.")
            }
            let newlySkippedInternalTestDrops = snapshot.progress.filter {
                $0.isComplete
                    && !$0.isClaimed
                    && !claimedDropIds.contains($0.dropId)
                    && isLikelyInternalTestProgress($0)
                    && !reportedInternalTestDropIds.contains($0.dropId)
            }
            reportedInternalTestDropIds.formUnion(newlySkippedInternalTestDrops.map(\.dropId))

            if claimable.isEmpty {
                if !hasLoggedNoClaimableDrops {
                    hasLoggedNoClaimableDrops = true
                    log("No claimable drops found in inventory")
                }
            } else {
                hasLoggedNoClaimableDrops = false
                log("Found \(claimable.count) claimable drop(s): \(claimable.map { $0.dropName }.joined(separator: ", "))")
            }
            if !newlySkippedInternalTestDrops.isEmpty {
                let names = newlySkippedInternalTestDrops.map(\.dropName).joined(separator: ", ")
                log("Skipped \(newlySkippedInternalTestDrops.count) internal/test claimable drop(s): \(names). They stay unclaimed and won't be reported again.")
            }

            for progress in claimable {
                guard repeatClaimGuard.beginClaim(progress.id) else { continue }
                defer { repeatClaimGuard.endClaim(progress.id) }
                let result = await claimService.claimDrop(progress)
                if result.success {
                    repeatClaimGuard.recordAcceptedClaim(
                        progress.id,
                        progress: progress,
                        accountConnected: allCampaigns.first { $0.id == progress.campaignId }?.isAccountConnected
                    )
                    didClaimAnyDrop = true
                    if result.confirmedByInventory {
                        await reportConfirmedClaim(progress)
                    } else {
                        log("Claim accepted for drop: \(result.dropName); awaiting inventory confirmation")
                    }
                } else {
                    let reason = result.error.map { " (\($0))" } ?? ""
                    let retry = result.retryAfter.map { " — retry in \(Int($0))s" } ?? ""
                    log("Warning: Drop claim returned not-success for \(progress.dropName)\(reason)\(retry)")
                }

                // Small delay between claims
                do {
                    try await runtimeClock.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    return didClaimAnyDrop
                }
            }

            if didClaimAnyDrop {
                let refreshedSnapshot = try await inventoryService.fetchInventory(forceRefresh: true)
                onOperationalEvent?(.successfulPoll)
                onOperationalEvent?(.inventoryRefresh)
                syncCampaigns(with: refreshedSnapshot)
                await confirmPendingClaims(in: refreshedSnapshot)
            }
        } catch {
            log("Error fetching claimable drops: \(error.localizedDescription)")
        }

        return didClaimAnyDrop
    }

    func configureClaimHistory() {
        guard let accountId = currentAccount?.id, repeatClaimGuardAccountId != accountId else { return }
        repeatClaimGuard = RepeatClaimGuard(fileURL: RepeatClaimGuard.fileURL(accountId: accountId))
        repeatClaimGuardAccountId = accountId
    }

    /// Only pending attempts are counted here, never historical rewards discovered on login.
    func confirmPendingClaims(in snapshot: InventorySnapshot) async {
        for progress in repeatClaimGuard.pendingClaims {
            let inventoryConfirms = snapshot.progress.contains { $0.id == progress.id && $0.isClaimed }
            let campaignConfirms = allCampaigns.first { $0.id == progress.campaignId }?
                .drops.contains { $0.id == progress.dropId && $0.isClaimed } == true
            if inventoryConfirms || campaignConfirms {
                await reportConfirmedClaim(progress)
            }
        }
    }

    func reportConfirmedClaim(_ progress: Progress) async {
        guard repeatClaimGuard.markClaimReported(progress) else { return }
        log("Claimed drop: \(progress.dropName) (confirmed by fresh inventory)")
        _ = progressEventTracker.markClaimed(
            campaignId: progress.campaignId,
            dropId: progress.dropId,
            dropLabel: progress.dropName
        )
        let drop = Drop(id: progress.dropId, name: progress.dropName, requiredMinutes: progress.requiredMinutes)
        recordActivityEvent(.dropClaimed, "Claimed \(progress.dropName)")
        onDropClaimed?(drop)
        session?.dropsClaimed += 1
        if showClaimNotifications, let notificationService {
            let campaignName = allCampaigns.first { $0.id == progress.campaignId }?.name ?? "Unknown Campaign"
            await notificationService.notifyDropClaimed(campaignName: campaignName, dropName: progress.dropName)
        }
    }

    private func isLikelyInternalTestProgress(_ progress: Progress) -> Bool {
        if progress.isLikelyInternalTestProgress {
            return true
        }

        guard let campaign = allCampaigns.first(where: { $0.id == progress.campaignId }) else {
            return false
        }

        if campaign.isLikelyInternalTestCampaign {
            return true
        }

        return campaign.drops.first(where: { $0.id == progress.dropId })?.isLikelyInternalTestDrop ?? false
    }

    func isLikelyInternalTestDropEvent(dropId: String, campaignId: String?) -> Bool {
        guard let campaignId,
              let campaign = allCampaigns.first(where: { $0.id == campaignId }) else {
            return false
        }

        if campaign.isLikelyInternalTestCampaign {
            return true
        }

        return campaign.drops.first(where: { $0.id == dropId })?.isLikelyInternalTestDrop ?? false
    }
}
