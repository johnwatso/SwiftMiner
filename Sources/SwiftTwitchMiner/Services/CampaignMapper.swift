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
            status: campaign.status.rawValue
        )
    }
}
