import Foundation

/// Static service for mapping internal models to UI-ready view data.
/// Combines campaign discovery, user inventory, and real-time progress.
public enum CampaignMapper {
    
    /// Maps a list of Campaigns to UI-ready CampaignViewData using the provided InventorySnapshot.
    /// - Parameters:
    ///   - campaigns: The global campaign list.
    ///   - inventory: The account-specific inventory snapshot (claimed benefits + progress).
    /// - Returns: A list of UI-ready view models.
    public static func map(
        campaigns: [Campaign],
        inventory: InventorySnapshot?
    ) -> [CampaignViewData] {
        let reconciled = inventory.map {
            DropsService.mergeInventory($0, into: campaigns, logClaims: false)
        } ?? campaigns

        return reconciled.map(mapReconciledCampaign)
    }
    
    /// Maps a single Campaign to UI-ready CampaignViewData.
    public static func mapSingle(
        campaign: Campaign,
        inventory: InventorySnapshot?
    ) -> CampaignViewData {
        let reconciled = inventory.flatMap {
            DropsService.mergeInventory($0, into: [campaign], logClaims: false).first
        } ?? campaign

        return mapReconciledCampaign(reconciled)
    }

    /// Converts a campaign whose per-drop claim and progress state has already been
    /// reconciled with inventory. Keeping this step shared with the miner prevents the UI
    /// from reinterpreting a reused benefit ID as proof that every matching tier was claimed.
    private static func mapReconciledCampaign(_ campaign: Campaign) -> CampaignViewData {
        let totalDrops = campaign.drops.count

        // DropsService.mergeInventory has already combined inventory benefit IDs with
        // per-drop progress records, including Twitch's reused-benefit edge cases.
        let claimedDrops = campaign.drops.filter(\.isClaimed)
        
        let claimedCount = claimedDrops.count
        let allClaimed = (claimedCount == totalDrops && totalDrops > 0)
        
        // Aggregate progress (Average of individual drop progresses, matching TDM)
        var sumOfProgress: Double = 0.0
        var totalMinutesRemaining: Double = 0.0
        
        for drop in campaign.drops {
            let req = Double(drop.requiredMinutes)
            var current: Double = 0.0

            if let prog = drop.progress {
                current = Double(min(prog.currentMinutes, drop.requiredMinutes))
            } else if drop.isClaimed {
                current = req
            }
            
            let dropProgress = (req > 0) ? (current / req) : 0.0
            sumOfProgress += dropProgress
            totalMinutesRemaining += (req - current)
        }
        
        let aggregateProgress = (totalDrops > 0) ? (sumOfProgress / Double(totalDrops)) : 0.0
        let timeRemaining: TimeInterval? = totalMinutesRemaining > 0 ? (totalMinutesRemaining * 60) : nil
        
        // Map individual drops to UI-ready view data
        let dropViewData: [DropViewData] = campaign.drops.map { drop in
            let isClaimed = drop.isClaimed

            var currentMinutes = 0
            var dropProgress = 0.0
            if let prog = drop.progress {
                currentMinutes = min(prog.currentMinutes, drop.requiredMinutes)
            } else if isClaimed {
                currentMinutes = drop.requiredMinutes
            }
            
            if drop.requiredMinutes > 0 {
                dropProgress = Double(currentMinutes) / Double(drop.requiredMinutes)
            }
            
            let isClaimable = !isClaimed && dropProgress >= 1.0
            
            // Earnable if linked, preconditions met, not yet 100% or claimed, and not subscription-gated without progress
            let preconditionsMet = drop.preconditionDrops.allSatisfy { pid in
                campaign.drops.first { $0.id == pid }?.isClaimed ?? true
            }
            let subscriptionMet = !drop.isSubscriptionRequired || (drop.progress?.currentMinutes ?? 0) > 0
            let isEarnable = !isClaimed && !isClaimable && campaign.isAccountConnected && preconditionsMet && subscriptionMet

            return DropViewData(
                id: drop.id,
                name: drop.name,
                description: drop.description,
                imageURL: drop.imageURL ?? drop.reward?.imageURL,
                rewardType: drop.reward?.type ?? .inGame,
                requiredMinutes: drop.requiredMinutes,
                currentMinutes: currentMinutes,
                progress: dropProgress,
                isClaimed: isClaimed,
                isClaimable: isClaimable,
                isEarnable: isEarnable,
                isSubscriptionRequired: drop.isSubscriptionRequired
            )
        }
        
        let miningStatus = campaign.miningStatus
        let relevance = campaign.relevance

        // Required logging: CampaignName → Status → Relevance
        Logger.campaigns.debug("\(campaign.name) → \(miningStatus.rawValue) → \(relevance.rawValue)")

        return CampaignViewData(
            id: campaign.id,
            gameId: campaign.game.id,
            gameName: campaign.game.name,
            campaignName: campaign.name,
            artworkURL: campaign.game.boxArtURL,
            progress: aggregateProgress,
            isClaimed: allClaimed,
            dropsClaimed: claimedCount,
            totalDrops: totalDrops,
            timeRemaining: timeRemaining,
            status: campaign.status.rawValue,
            miningStatus: miningStatus,
            isAccountConnected: campaign.isAccountConnected,
            relevance: relevance,
            startDate: campaign.startDate,
            endDate: campaign.endDate,
            drops: dropViewData
        )
    }
}

// MARK: - Feed Composition

public extension CampaignMapper {

    /// Builds the ordered feed from a list of CampaignViewData.
    /// Order: prioritised → active → closed → recent.
    /// The feed is NEVER empty if any campaigns exist.
    /// Closed campaigns (ended, all claimed) are shown separately from active ones.
    static func composeFeed(from campaigns: [CampaignViewData]) -> [CampaignViewData] {
        let prioritised = campaigns.filter { $0.curatedFeedBucket == .prioritised }
        let active      = campaigns.filter { $0.curatedFeedBucket == .active }
        let closed      = campaigns.filter { $0.curatedFeedBucket == .closed }
        let recent      = campaigns.filter { $0.curatedFeedBucket == .recent }
        // irrelevant campaigns are excluded from the feed but not deleted
        return prioritised + active + closed + recent
    }
}
