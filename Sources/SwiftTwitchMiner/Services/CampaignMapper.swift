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
        return campaigns.map { campaign in
            mapSingle(campaign: campaign, inventory: inventory)
        }
    }
    
    /// Maps a single Campaign to UI-ready CampaignViewData.
    public static func mapSingle(
        campaign: Campaign,
        inventory: InventorySnapshot?
    ) -> CampaignViewData {
        let totalDrops = campaign.drops.count
        
        // SOURCE OF TRUTH: Claimed state is determined SOLELY by benefit IDs in the inventory snapshot.
        // progress.isClaimed is transient and unreliable, so it is intentionally NOT used.
        let claimedDrops = campaign.drops.filter { drop in
            drop.benefitIds.contains { bid in
                inventory?.benefitIDs.contains(bid) ?? false
            }
        }
        
        let claimedCount = claimedDrops.count
        let allClaimed = (claimedCount == totalDrops && totalDrops > 0)
        
        // Aggregate progress (Average of individual drop progresses, matching TDM)
        var sumOfProgress: Double = 0.0
        var totalMinutesRemaining: Double = 0.0
        
        for drop in campaign.drops {
            let req = Double(drop.requiredMinutes)
            var current: Double = 0.0
            
            if let prog = inventory?.progress.first(where: { $0.dropId == drop.id }) {
                current = Double(min(prog.currentMinutes, drop.requiredMinutes))
            } else {
                // If claimed via benefit but no progress entry, treat as 100%
                let isClaimedByBenefit = drop.benefitIds.contains { bid in
                    inventory?.benefitIDs.contains(bid) ?? false
                }
                if isClaimedByBenefit {
                    current = req
                }
            }
            
            let dropProgress = (req > 0) ? (current / req) : 0.0
            sumOfProgress += dropProgress
            totalMinutesRemaining += (req - current)
        }
        
        let aggregateProgress = (totalDrops > 0) ? (sumOfProgress / Double(totalDrops)) : 0.0
        let timeRemaining: TimeInterval? = totalMinutesRemaining > 0 ? (totalMinutesRemaining * 60) : nil
        
        // Map individual drops to UI-ready view data
        let dropViewData: [DropViewData] = campaign.drops.map { drop in
            let isClaimed = drop.benefitIds.contains { bid in
                inventory?.benefitIDs.contains(bid) ?? false
            }
            
            var currentMinutes = 0
            var dropProgress = 0.0
            if let prog = inventory?.progress.first(where: { $0.dropId == drop.id }) {
                currentMinutes = min(prog.currentMinutes, drop.requiredMinutes)
            } else if isClaimed {
                currentMinutes = drop.requiredMinutes
            }
            
            if drop.requiredMinutes > 0 {
                dropProgress = Double(currentMinutes) / Double(drop.requiredMinutes)
            }
            
            let isClaimable = !isClaimed && dropProgress >= 1.0
            
            // Earnable if linked, preconditions met, and not yet 100% or claimed
            let preconditionsMet = drop.preconditionDrops.allSatisfy { pid in
                campaign.drops.first { $0.id == pid }?.isClaimed ?? true
            }
            let isEarnable = !isClaimed && !isClaimable && campaign.isAccountConnected && preconditionsMet
            
            return DropViewData(
                id: drop.id,
                name: drop.name,
                description: drop.description,
                imageURL: drop.imageURL,
                rewardType: drop.reward?.type ?? .inGame,
                requiredMinutes: drop.requiredMinutes,
                currentMinutes: currentMinutes,
                progress: dropProgress,
                isClaimed: isClaimed,
                isClaimable: isClaimable,
                isEarnable: isEarnable
            )
        }
        
        let miningStatus = campaign.miningStatus
        let relevance = campaign.relevance

        // Required logging: CampaignName → Status → Relevance
        print("[Campaign] \(campaign.name) → \(miningStatus.rawValue) → \(relevance.rawValue)")

        return CampaignViewData(
            id: campaign.id,
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
    /// Order: prioritised → active → recent.
    /// The feed is NEVER empty if any campaigns exist.
    static func composeFeed(from campaigns: [CampaignViewData]) -> [CampaignViewData] {
        let prioritised = campaigns.filter { $0.relevance == .prioritised }
        let active      = campaigns.filter { $0.relevance == .active }
        let recent      = campaigns.filter { $0.relevance == .recent }
        // irrelevant campaigns are excluded from the feed but not deleted
        return prioritised + active + recent
    }
}
