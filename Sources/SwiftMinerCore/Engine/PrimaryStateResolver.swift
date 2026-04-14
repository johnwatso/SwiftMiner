import Foundation

/// Standalone utility to resolve the PrimaryState for a miner.
/// Used to unify multiple internal states into a single, consistent user-facing model.
public enum PrimaryStateResolver {
    
    /// Resolves the PrimaryState for a given miner.
    /// 
    /// Precedence Rules (Task 2):
    /// 1. `.blocked`: If ANY active campaign is blocked (auth, connection).
    /// 2. `.mining`: If ANY campaign is actively mining an incomplete drop.
    /// 3. `.ready`: If ANY campaign has work to do (earnable drops < 100% progress).
    /// 4. `.completed`: If ALL drops across all relevant campaigns are earned (100% progress).
    @MainActor
    public static func resolve(for miner: MinerManager.ManagedMiner) -> PrimaryState {
        // Filter out irrelevant campaigns (no drops) AND hard exclude "Just Chatting"
        let relevantCampaigns = miner.allCampaigns.filter { campaign in
            if campaign.drops.isEmpty { return false }
            
            // Hard exclude "Just Chatting"
            let name = campaign.game.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let id = campaign.game.id.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.localizedCaseInsensitiveCompare("Just Chatting") == .orderedSame || id == "509658" {
                return false
            }
            
            return true
        }
        
        // 1. Blocked Check (Highest Priority)
        
        // 1a. Global Auth Block
        if miner.needsAuth {
            print("[PrimaryStateResolver] needsAuth=true → .blocked(.accountNotLinked)")
            return .blocked(reasons: [.accountNotLinked])
        }
        
        // 1b. Specific Campaign Block (Disconnected)
        // John: "disconnected campaign account... must show 'Link Required'"
        // Only blocks if the campaign is active, needs linking, and isn't already earned.
        let disconnected = relevantCampaigns.filter { campaign in
            campaign.isTimeActive && 
            !campaign.isAccountConnected && 
            campaign.drops.contains { !isEarned($0) }
        }
        if !disconnected.isEmpty {
            print("[PrimaryStateResolver] \(disconnected.count) disconnected active campaign(s) → .blocked(.accountNotLinked)")
            return .blocked(reasons: [.accountNotLinked])
        }
        
        // 1c. No Live Streams Block (Stable Engine State)
        if miner.status == .waitingForStream {
            print("[PrimaryStateResolver] status=.waitingForStream → .blocked(.noLiveStreams)")
            return .blocked(reasons: [.noLiveStreams])
        }
        
        // 1d. Eligibility Block (No campaigns at all)
        if relevantCampaigns.isEmpty {
            print("[PrimaryStateResolver] no campaigns with drops → .blocked(.noEligibleCampaign)")
            return .blocked(reasons: [.noEligibleCampaign])
        }
        
        // If NO campaigns are either active or already completed, we are blocked (e.g. all upcoming)
        let hasActiveOrComplete = relevantCampaigns.contains { campaign in
            campaign.isTimeActive || campaign.drops.allSatisfy { isEarned($0) }
        }
        if !hasActiveOrComplete {
            print("[PrimaryStateResolver] all \(relevantCampaigns.count) campaigns are upcoming/inactive → .blocked(.noEligibleCampaign)")
            return .blocked(reasons: [.noEligibleCampaign])
        }

        // 2. Mining Check (Second Priority)
        // Task 3.3: "mining = active miner + incomplete drops"
        if miner.status == .watching,
           let campaignId = miner.currentCampaignId,
           let campaign = miner.allCampaigns.first(where: { $0.id == campaignId }) {
            
            // Find the active drop (first unclaimed)
            if let activeDrop = campaign.drops.first(where: { !$0.isClaimed }) {
                let dropState = miner.stateStore?.dropStates.first { $0.dropId == activeDrop.id }
                let currentMinutes = dropState?.progressMinutes ?? activeDrop.progress?.currentMinutes ?? 0
                let requiredMinutes = dropState?.requiredMinutes ?? activeDrop.requiredMinutes
                
                // Only return .mining if there is actual progress left to earn.
                if currentMinutes < requiredMinutes {
                    let fraction = requiredMinutes > 0 ? Double(currentMinutes) / Double(requiredMinutes) : 0
                    
                    let progress = MiningProgress(
                        gameName: campaign.game.name,
                        campaignName: campaign.name,
                        dropName: activeDrop.name,
                        progressFraction: min(1.0, max(0.0, fraction)),
                        minutesRemaining: max(0, requiredMinutes - currentMinutes)
                    )
                    print("[PrimaryStateResolver] status=.watching campaign=\(campaign.name) drop=\(activeDrop.name) progress=\(String(format: "%.2f", fraction)) → .mining")
                    return .mining(progress: progress)
                }
            }
        }
        
        // 3. Ready Check (Third Priority)
        // Task 3.3: "ready = eligible but not started"
        // Eligible here means "has drops with progress < 100%".
        let hasEarnable = relevantCampaigns.contains { campaign in
            campaign.isTimeActive && campaign.isAccountConnected && campaign.drops.contains { !isEarned($0) }
        }
        
        if hasEarnable {
            print("[PrimaryStateResolver] hasEarnable=true → .ready")
            return .ready
        }
        
        // 4. Completed Check (Lowest Priority)
        // Task 1.4: "all drops earned (progress.isComplete == true for all) -> .completed"
        // Task 3.3: "completed = earnedDrops == totalDrops"
        let allEarned = relevantCampaigns.allSatisfy { campaign in
            campaign.drops.allSatisfy { isEarned($0) }
        }
        
        if allEarned {
            print("[PrimaryStateResolver] all drops across \(relevantCampaigns.count) campaigns earned → .completed")
            return .completed
        }
        
        // 5. Fallback (Scanning/Idle/Claiming)
        print("[PrimaryStateResolver] fallback → .ready")
        return .ready
    }

    // MARK: - Private Helpers

    private static func isEarned(_ drop: Drop) -> Bool {
        // Task 3: True completion only when claimed. Prevent false "completed"
        // when drops are watched but not yet confirmed by Twitch.
        drop.isClaimed
    }
}
