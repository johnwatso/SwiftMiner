import Foundation

/// Static utility for merging global campaign data with account-specific states (Phase 3).
///
/// This service implements the "Merge Layer" that joins discovery data with
/// user progress data without mutating the underlying models.
public enum MergeService {
    
    /// Merges global campaigns with multiple accounts' drop states.
    /// - Parameters:
    ///   - campaigns: The global list of campaigns (from CampaignStore)
    ///   - accountStates: A dictionary mapping accountId to their list of drop states
    /// - Returns: A list of DisplayCampaigns ready for the UI.
    public static func merge(
        campaigns: [Campaign],
        accountStates: [String: [DropState]]
    ) -> [DisplayCampaign] {
        // Flat map of dropId -> [DropState]
        var statesByDropId: [String: [DropState]] = [:]

        for (_, states) in accountStates {
            for state in states {
                statesByDropId[state.dropId, default: []].append(state)
            }
        }
        
        return campaigns.map { campaign in
            let displayDrops = campaign.drops.map { drop in
                let states = statesByDropId[drop.id] ?? []
                
                // Debug logging as requested in Phase 3
                if !states.isEmpty {
                    print("[Merge] Drop \(drop.name) (\(drop.id)) → \(states.count) states attached")
                }
                
                return DisplayDrop(base: drop, states: states)
            }
            
            return DisplayCampaign(base: campaign, drops: displayDrops)
        }
    }
}
