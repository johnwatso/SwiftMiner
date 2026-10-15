import Foundation

// Claiming ready drops, and the heuristics that keep Twitch's internal test campaigns from
// being mistaken for real progress.
//
// Split out of MinerEngine.swift, which had grown past the point where one file could be read.

/// Remembers drop instances whose claim Twitch accepted but which inventory keeps listing as
/// unclaimed (seen with an account not linked to the game: one account re-claimed the same seven
/// drops every five minutes for ~39 hours). After `maxAcceptedClaims` accepted claims for one
/// instance the engine stops trying, so the claim counter, notifications and per-cycle claim time
/// stop being inflated by a claim that never sticks.
struct RepeatClaimGuard {
    static let maxAcceptedClaims = 2

    private var acceptedClaims: [String: Int] = [:]
    private var reportedSuppressed: Set<String> = []

    func isSuppressed(_ instanceId: String) -> Bool {
        acceptedClaims[instanceId, default: 0] >= Self.maxAcceptedClaims
    }

    mutating func recordAcceptedClaim(_ instanceId: String) {
        acceptedClaims[instanceId, default: 0] += 1
    }

    /// True only the first time an instance is reported as suppressed, so the warning is logged once.
    mutating func markReported(_ instanceId: String) -> Bool {
        reportedSuppressed.insert(instanceId).inserted
    }
}

extension MinerEngine {
    func claimReadyDrops(forceInventoryRefresh: Bool = false) async -> Bool {
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
                log("Warning: Twitch accepted the claim for \(names) but inventory still lists it as unclaimed.\(linkHint) Not retrying it again this run.")
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
                let result = await claimService.claimDrop(progress)
                if result.success {
                    let confirmation = result.confirmedByInventory ? " (confirmed by fresh inventory)" : ""
                    log("Claimed drop: \(result.dropName)\(confirmation)")
                    repeatClaimGuard.recordAcceptedClaim(progress.id)

                    let drop = Drop(
                        id: progress.dropId,
                        name: progress.dropName,
                        requiredMinutes: progress.requiredMinutes
                    )
                    _ = progressEventTracker.markClaimed(
                        campaignId: progress.campaignId,
                        dropId: progress.dropId,
                        dropLabel: progress.dropName.isEmpty ? dropLabel(for: progress.dropId, campaignId: progress.campaignId) : progress.dropName
                    )
                    recordActivityEvent(.dropClaimed, "Claimed \(result.dropName)")
                    onDropClaimed?(drop)
                    session?.dropsClaimed += 1
                    didClaimAnyDrop = true

                    // Send local notification if enabled
                    if showClaimNotifications, let notificationService = notificationService {
                        await notificationService.notifyDropClaimed(
                            campaignName: result.campaignName,
                            dropName: result.dropName
                        )
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
            }
        } catch {
            log("Error fetching claimable drops: \(error.localizedDescription)")
        }

        return didClaimAnyDrop
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
