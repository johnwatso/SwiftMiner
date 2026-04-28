import Foundation

/// Resolved status for a specific campaign from a miner's perspective (Phase: Attention System).
public enum CampaignActivityStatus: Sendable, Equatable {
    /// Actively watching/mining this campaign.
    case watching
    
    /// Campaign is active but the account is not linked.
    case requiresLink
    
    /// Campaign is upcoming.
    case upcoming
    
    /// Campaign has expired.
    case expired
    
    /// Campaign has no remaining rewards.
    case completed
    
    /// Campaign is live, but no participating channels are broadcasting.
    case waitingForStream
    
    /// The user-facing label for this status.
    public var label: String {
        switch self {
        case .watching: return "Watching"
        case .requiresLink: return "Requires linked account"
        case .upcoming: return "Campaign upcoming"
        case .expired: return "Campaign expired"
        case .completed: return "Completed"
        case .waitingForStream: return "Waiting — No channels live"
        }
    }
}

// MARK: - Factory

extension Campaign {
    /// Resolves the activity status for this campaign relative to a specific miner.
    @MainActor
    public func activityStatus(for miner: MinerManager.ManagedMiner) -> CampaignActivityStatus {
        // 1. Account linkage (highest priority issue)
        if !isAccountConnected {
            return .requiresLink
        }

        let statesByDropId = Dictionary(
            uniqueKeysWithValues: (miner.stateStore?.dropStates ?? []).map { ($0.dropId, $0) }
        )
        let allDropsComplete = !drops.isEmpty && drops.allSatisfy { drop in
            if drop.isClaimed { return true }
            guard let state = statesByDropId[drop.id] else { return false }
            return state.isClaimed || state.isComplete
        }

        if allDropsComplete {
            return .completed
        }
        
        // 2. Time window
        if Date() < startDate {
            return .upcoming
        }
        if Date() > endDate {
            return .expired
        }
        
        // 3. Eligibility (all claimed or precondition locked)
        if eligibleDrops.isEmpty {
            return .completed
        }
        
        // 4. Execution state
        if miner.status == .watching && miner.currentCampaignId == id {
            return .watching
        }
        
        // 5. Fallback (campaign is ready but nothing to watch right now)
        return .waitingForStream
    }
}
