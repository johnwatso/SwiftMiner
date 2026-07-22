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
            let result = progressEventTracker.observe(observation)
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
            lastProgressUpdateAt = Date()

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
}

struct TrackedDropProgress: Sendable, Equatable {
    let dropLabel: String
    let currentMinutes: Int
    let requiredMinutes: Int?
    let isClaimed: Bool
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

        if let previous, previous.isClaimed {
            cache[key] = TrackedDropProgress(
                dropLabel: observation.dropLabel,
                currentMinutes: previous.currentMinutes,
                requiredMinutes: mergedRequired,
                isClaimed: true
            )
            return DropProgressUpdateResult(
                key: key,
                source: observation.source,
                previousMinutes: previous.currentMinutes,
                transition: .none
            )
        }

        if let previous, observation.currentMinutes < previous.currentMinutes {
            cache[key] = TrackedDropProgress(
                dropLabel: observation.dropLabel,
                currentMinutes: previous.currentMinutes,
                requiredMinutes: mergedRequired,
                isClaimed: previous.isClaimed
            )
            return DropProgressUpdateResult(
                key: key,
                source: observation.source,
                previousMinutes: previous.currentMinutes,
                transition: .regression(previousMinutes: previous.currentMinutes, observedMinutes: observation.currentMinutes)
            )
        }

        let currentMinutes = max(observation.currentMinutes, previous?.currentMinutes ?? 0)
        let current = TrackedDropProgress(
            dropLabel: observation.dropLabel,
            currentMinutes: currentMinutes,
            requiredMinutes: mergedRequired,
            isClaimed: false
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
                )
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
                )
            )
        }

        return DropProgressUpdateResult(
            key: key,
            source: observation.source,
            previousMinutes: previous?.currentMinutes,
            transition: .none
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
            isClaimed: true
        )

        return DropProgressUpdateResult(
            key: key,
            source: .pubSub,
            previousMinutes: previous?.currentMinutes,
            transition: alreadyClaimed ? .none : .claimed(dropLabel: dropLabel)
        )
    }

    func isClaimable(minutes: Int, requiredMinutes: Int?, isClaimed: Bool) -> Bool {
        guard !isClaimed, let requiredMinutes else { return false }
        return minutes >= requiredMinutes
    }
}
