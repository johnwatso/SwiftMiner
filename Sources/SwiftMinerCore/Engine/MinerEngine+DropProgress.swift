// Inventory progress acknowledgement and drop-progress event tracking
// for MinerEngine. Split from MinerEngine.swift; same actor, same isolation.
import Foundation

extension MinerEngine {
    func acknowledgeInventoryProgress(
        _ snapshot: InventorySnapshot,
        campaignId: String,
        context: String,
        publishProgressUpdate: Bool = true
    ) async -> Bool {
        let mergedCampaigns = DropsService.mergeInventory(snapshot, into: allCampaigns)
        allCampaigns = mergedCampaigns

        let updatedCandidates = candidateCampaigns(
            from: mergedCampaigns,
            priorityGames: priorityGames,
            excludedGames: excludedGames,
            strategy: miningStrategy
        )
        onCampaignUpdate?(updatedCandidates)

        let currentCampaignProgress = snapshot.progress.filter { progress in
            progress.campaignId == campaignId && !progress.isClaimed
        }

        var acknowledged = false
        for progress in currentCampaignProgress {
            let observation = DropProgressObservation(
                campaignId: progress.campaignId,
                dropId: progress.dropId,
                dropLabel: progress.dropName.isEmpty ? dropLabel(for: progress.dropId, campaignId: progress.campaignId) : progress.dropName,
                currentMinutes: progress.currentMinutes,
                requiredMinutes: progress.requiredMinutes,
                source: .inventory
            )
            let result = observeDropProgress(observation)
            traceGQL(
                "Inventory progress \(context) drop=\(progress.dropId) parsedCurrent=\(progress.currentMinutes) " +
                "previous=\(result.previousMinutes.map(String.init) ?? "nil") transition=\(result.transition.traceDescription)"
            )

            guard result.shouldAcknowledgeServerProgress else { continue }

            if let message = formatProgressTransition(result.transition) {
                log("\(message) from Twitch inventory")
            }

            acknowledged = true
        }

        if acknowledged {
            extraMinutesWatched = 0
            resetProgressStallClock()

            if publishProgressUpdate,
               let progress = try? await dropsService.getOverallProgress() {
                onProgressUpdate?(progress)
            }
        }

        return acknowledged
    }

    /// Refresh all server-confirmed progress for the active campaign after any individual
    /// progress signal advances. Twitch can advance multiple drops in parallel, so updating
    /// only the drop named by PubSub/current-session GQL can leave the rest of the UI stale.
    func refreshCampaignProgress(campaignId: String?, context: String) async {
        if let campaignId, !campaignId.isEmpty {
            do {
                let inventoryService = await dropsService.getInventoryService()
                let snapshot = try await inventoryService.fetchInventory(forceRefresh: true)
                onOperationalEvent?(.successfulPoll)
                onOperationalEvent?(.inventoryRefresh)
                _ = await acknowledgeInventoryProgress(
                    snapshot,
                    campaignId: campaignId,
                    context: context,
                    publishProgressUpdate: false
                )
            } catch {
                emitIssue(error)
                log("Could not refresh campaign-wide drop progress: \(error.localizedDescription)")
            }
        }

        // Publish once after the merge. This also preserves the prior single-drop update
        // behavior if no campaign ID is available or the forced refresh fails.
        if let progress = try? await dropsService.getOverallProgress() {
            onProgressUpdate?(progress)
        }
    }

    func findDrop(dropId: String, campaignId: String?) -> Drop? {
        if let campaignId,
           let campaign = allCampaigns.first(where: { $0.id == campaignId }),
           let drop = campaign.drops.first(where: { $0.id == dropId }) {
            return drop
        }

        return allCampaigns
            .lazy
            .flatMap(\.drops)
            .first(where: { $0.id == dropId })
    }

    func formatProgressTransition(_ transition: DropProgressTransition) -> String? {
        switch transition {
        case .none, .regression:
            return nil
        case .progress(let dropLabel, let deltaMinutes, let currentMinutes, let requiredMinutes):
            if let requiredMinutes {
                return "Progress +\(deltaMinutes) min on \(dropLabel) (\(currentMinutes)/\(requiredMinutes) min)"
            }
            return "Progress +\(deltaMinutes) min on \(dropLabel) (\(currentMinutes) min)"
        case .claimable(let dropLabel, let currentMinutes, let requiredMinutes):
            return "Drop claimable: \(dropLabel) (\(currentMinutes)/\(requiredMinutes) min)"
        case .claimed(let dropLabel):
            return "Drop claimed: \(dropLabel)"
        }
    }
    
}

struct DropProgressCacheKey: Hashable, Sendable {
    let campaignId: String?
    let dropId: String
}

enum DropProgressSource: String, Sendable {
    case pubSub
    case gqlPoll
    case inventory
}

struct DropProgressObservation: Sendable {
    let campaignId: String?
    let dropId: String
    let dropLabel: String
    let currentMinutes: Int
    let requiredMinutes: Int?
    let source: DropProgressSource
    var observedAt: Date = Date()
    var observedUptimeNanoseconds: UInt64? = nil
}

struct TrackedDropProgress: Sendable, Equatable {
    let dropLabel: String
    let currentMinutes: Int
    let requiredMinutes: Int?
    let isClaimed: Bool
    /// When `currentMinutes` last advanced. Unchanged and stale samples must not move this
    /// baseline or frequent polling would make legitimate batched progress look impossible.
    var progressBaselineAt: Date = .distantPast
    var progressBaselineUptimeNanoseconds: UInt64? = nil
}

extension MinerEngine {
    /// Records a drop progress sample and reports any minutes it genuinely earned.
    ///
    /// Every observation goes through here so the earning signal stays tied to real
    /// per-drop transitions. Deriving it from aggregate totals instead does not work:
    /// those move whenever campaigns enter or leave the account's set or a drop is
    /// claimed, so they both invent progress that never happened and hide progress
    /// that did.
    @discardableResult
    func observeDropProgress(_ observation: DropProgressObservation) -> DropProgressUpdateResult {
        var monotonicObservation = observation
        if monotonicObservation.observedUptimeNanoseconds == nil {
            monotonicObservation.observedUptimeNanoseconds = runtimeClock.nowNanoseconds()
        }
        let result = progressEventTracker.observe(monotonicObservation)

        // Telemetry that cannot be true should say so at the moment it happens, rather than
        // waiting to be spotted in an exported report days later. Both ledger defects would
        // have announced themselves here on the first cycle.
        let discarded = result.implausibleMinutesDiscarded
        if discarded > 0 {
            let elapsed = Int((result.secondsSinceProgressBaseline ?? 0) / 60)
            log(
                "Discarded \(discarded) implausible drop minute(s) for \(observation.dropLabel): "
                + "reported \(result.reportedEarnedMinutes) after \(elapsed) min since the progress baseline"
            )
            recordActivityEvent(
                .error,
                "Implausible drop progress discarded (\(discarded) min) for \(observation.dropLabel)"
            )
        }

        let earned = result.earnedMinutes
        if earned > 0 {
            onEarnedProgress?(earned)
        }
        return result
    }
}

enum DropProgressTransition: Sendable, Equatable {
    case none
    case progress(dropLabel: String, deltaMinutes: Int, currentMinutes: Int, requiredMinutes: Int?)
    case claimable(dropLabel: String, currentMinutes: Int, requiredMinutes: Int)
    case claimed(dropLabel: String)
    case regression(previousMinutes: Int, observedMinutes: Int)

    var traceDescription: String {
        switch self {
        case .none:
            return "none"
        case .progress(let dropLabel, let deltaMinutes, let currentMinutes, let requiredMinutes):
            if let requiredMinutes {
                return "progress[\(dropLabel)] delta=\(deltaMinutes) current=\(currentMinutes)/\(requiredMinutes)"
            }
            return "progress[\(dropLabel)] delta=\(deltaMinutes) current=\(currentMinutes)"
        case .claimable(let dropLabel, let currentMinutes, let requiredMinutes):
            return "claimable[\(dropLabel)] current=\(currentMinutes)/\(requiredMinutes)"
        case .claimed(let dropLabel):
            return "claimed[\(dropLabel)]"
        case .regression(let previousMinutes, let observedMinutes):
            return "regression previous=\(previousMinutes) observed=\(observedMinutes)"
        }
    }
}

struct DropProgressUpdateResult: Sendable, Equatable {
    let key: DropProgressCacheKey
    let source: DropProgressSource
    let previousMinutes: Int?
    let transition: DropProgressTransition

    var shouldAcknowledgeServerProgress: Bool {
        switch transition {
        case .progress, .claimable, .claimed:
            return true
        case .none, .regression:
            return false
        }
    }

    /// Wall-clock seconds since this drop's accepted progress baseline was established.
    /// `nil` on a first sighting.
    let secondsSinceProgressBaseline: TimeInterval?

    /// Slack over the wall-clock bound, absorbing clock skew and Twitch crediting in
    /// batches rather than smoothly.
    static let plausibilitySlackMinutes = 2

    /// What the observation claimed to have earned, before any plausibility check.
    ///
    /// Only movement between two observations counts. The first sighting of a drop reports
    /// everything already banked against it — progress that may have been earned days ago,
    /// or by another device — so it establishes a baseline and earns nothing. Counting it
    /// meant every switch to a campaign with existing progress credited that campaign's
    /// entire history at once, which is how a single account booked 540 minutes in one hour.
    var reportedEarnedMinutes: Int {
        guard let previousMinutes else { return 0 }
        switch transition {
        case .progress(_, let deltaMinutes, _, _):
            return max(0, deltaMinutes)
        case .claimable(_, let currentMinutes, _):
            return max(0, currentMinutes - previousMinutes)
        case .none, .claimed, .regression:
            return 0
        }
    }

    /// The most a drop could honestly have gained since its accepted progress baseline. A
    /// drop accrues at most one minute per minute, so anything beyond the elapsed wall clock
    /// either was not earned here — it may have been watched on another device — or is a
    /// defect in our own accounting. Either way it must not inflate this miner's ledger.
    var plausibleEarnedMinutesBound: Int {
        guard let secondsSinceProgressBaseline else { return 0 }
        return Int(max(0, secondsSinceProgressBaseline) / 60) + Self.plausibilitySlackMinutes
    }

    /// Minutes of verified drop progress this observation added, bounded by what was
    /// physically possible in the elapsed time.
    var earnedMinutes: Int {
        min(reportedEarnedMinutes, plausibleEarnedMinutesBound)
    }

    /// Minutes the observation claimed that the elapsed time could not account for.
    /// Non-zero means the earning signal is misreporting and should be investigated —
    /// it is the check that would have caught 540 minutes booked in a single hour.
    var implausibleMinutesDiscarded: Int {
        max(0, reportedEarnedMinutes - earnedMinutes)
    }
}

struct DropProgressEventTracker: Sendable {
    private(set) var cache: [DropProgressCacheKey: TrackedDropProgress] = [:]

    /// Minutes left on the campaign's most-advanced unclaimed drop, when the
    /// tracker has verified progress and a known requirement for it.
    func remainingMinutesToNextClaim(campaignId: String) -> Int? {
        cache.compactMap { key, tracked -> Int? in
            guard key.campaignId == campaignId,
                  !tracked.isClaimed,
                  tracked.currentMinutes > 0,
                  let required = tracked.requiredMinutes else { return nil }
            return max(0, required - tracked.currentMinutes)
        }.min()
    }

    mutating func observe(_ observation: DropProgressObservation) -> DropProgressUpdateResult {
        let key = DropProgressCacheKey(campaignId: observation.campaignId, dropId: observation.dropId)
        let previous = cache[key]
        let mergedRequired = observation.requiredMinutes ?? previous?.requiredMinutes
        // Measure from the sample that established the accepted progress baseline.
        // Unchanged and regressing polls do not reset it: Twitch can credit in batches, and
        // polling between credits must not make those batches look impossible.
        let elapsed = previous.map { tracked -> TimeInterval in
            if let observedTick = observation.observedUptimeNanoseconds,
               let baselineTick = tracked.progressBaselineUptimeNanoseconds,
               observedTick >= baselineTick {
                return TimeInterval(observedTick - baselineTick) / 1_000_000_000
            }
            return max(0, observation.observedAt.timeIntervalSince(tracked.progressBaselineAt))
        }

        if let previous, previous.isClaimed {
            cache[key] = TrackedDropProgress(
                dropLabel: observation.dropLabel,
                currentMinutes: previous.currentMinutes,
                requiredMinutes: mergedRequired,
                isClaimed: true,
                progressBaselineAt: previous.progressBaselineAt,
                progressBaselineUptimeNanoseconds: previous.progressBaselineUptimeNanoseconds
            )
            return DropProgressUpdateResult(
                key: key,
                source: observation.source,
                previousMinutes: previous.currentMinutes,
                transition: .none,
                secondsSinceProgressBaseline: elapsed
            )
        }

        if let previous, observation.currentMinutes < previous.currentMinutes {
            cache[key] = TrackedDropProgress(
                dropLabel: observation.dropLabel,
                currentMinutes: previous.currentMinutes,
                requiredMinutes: mergedRequired,
                isClaimed: previous.isClaimed,
                progressBaselineAt: previous.progressBaselineAt,
                progressBaselineUptimeNanoseconds: previous.progressBaselineUptimeNanoseconds
            )
            return DropProgressUpdateResult(
                key: key,
                source: observation.source,
                previousMinutes: previous.currentMinutes,
                transition: .regression(previousMinutes: previous.currentMinutes, observedMinutes: observation.currentMinutes),
                secondsSinceProgressBaseline: elapsed
            )
        }

        let currentMinutes = max(observation.currentMinutes, previous?.currentMinutes ?? 0)
        let current = TrackedDropProgress(
            dropLabel: observation.dropLabel,
            currentMinutes: currentMinutes,
            requiredMinutes: mergedRequired,
            isClaimed: false,
            progressBaselineAt: currentMinutes > (previous?.currentMinutes ?? -1)
                ? observation.observedAt
                : (previous?.progressBaselineAt ?? observation.observedAt),
            progressBaselineUptimeNanoseconds: currentMinutes > (previous?.currentMinutes ?? -1)
                ? observation.observedUptimeNanoseconds
                : previous?.progressBaselineUptimeNanoseconds
        )
        cache[key] = current

        let previousClaimable = previous.map { isClaimable(minutes: $0.currentMinutes, requiredMinutes: $0.requiredMinutes, isClaimed: $0.isClaimed) } ?? false
        let currentClaimable = isClaimable(minutes: currentMinutes, requiredMinutes: mergedRequired, isClaimed: false)
        if currentClaimable && !previousClaimable {
            return DropProgressUpdateResult(
                key: key,
                source: observation.source,
                previousMinutes: previous?.currentMinutes,
                transition: .claimable(
                    dropLabel: observation.dropLabel,
                    currentMinutes: currentMinutes,
                    requiredMinutes: mergedRequired ?? currentMinutes
                ),
                secondsSinceProgressBaseline: elapsed
            )
        }

        let delta = currentMinutes - (previous?.currentMinutes ?? 0)
        if delta > 0 {
            return DropProgressUpdateResult(
                key: key,
                source: observation.source,
                previousMinutes: previous?.currentMinutes,
                transition: .progress(
                    dropLabel: observation.dropLabel,
                    deltaMinutes: delta,
                    currentMinutes: currentMinutes,
                    requiredMinutes: mergedRequired
                ),
                secondsSinceProgressBaseline: elapsed
            )
        }

        return DropProgressUpdateResult(
            key: key,
            source: observation.source,
            previousMinutes: previous?.currentMinutes,
            transition: .none,
            secondsSinceProgressBaseline: elapsed
        )
    }

    mutating func markClaimed(campaignId: String?, dropId: String, dropLabel: String) -> DropProgressUpdateResult {
        let key = DropProgressCacheKey(campaignId: campaignId, dropId: dropId)
        let previous = cache[key]
        let alreadyClaimed = previous?.isClaimed ?? false
        cache[key] = TrackedDropProgress(
            dropLabel: dropLabel,
            currentMinutes: previous?.currentMinutes ?? 0,
            requiredMinutes: previous?.requiredMinutes,
            isClaimed: true,
            progressBaselineAt: previous?.progressBaselineAt ?? .distantPast,
            progressBaselineUptimeNanoseconds: previous?.progressBaselineUptimeNanoseconds
        )

        return DropProgressUpdateResult(
            key: key,
            source: .pubSub,
            previousMinutes: previous?.currentMinutes,
            transition: alreadyClaimed ? .none : .claimed(dropLabel: dropLabel),
            // A claim credits no minutes, so no elapsed bound is needed.
            secondsSinceProgressBaseline: nil
        )
    }

    func isClaimable(minutes: Int, requiredMinutes: Int?, isClaimed: Bool) -> Bool {
        guard !isClaimed, let requiredMinutes else { return false }
        return minutes >= requiredMinutes
    }
}
