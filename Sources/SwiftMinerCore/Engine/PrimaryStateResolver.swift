import Foundation

/// Standalone utility to resolve the PrimaryState for a miner.
/// Uses the per-game state list (MinerGameState) as the source of truth,
/// then maps to the user-facing PrimaryState enum.
public enum PrimaryStateResolver {

    /// Resolves the PrimaryState for a given miner.
    ///
    /// Derives from the per-game state list to ensure a single, consistent resolution:
    /// 1. `.mining`: If ANY game state is actively watching with progress.
    /// 2. `.ready`: If ANY game state is idle but earnable.
    /// 3. `.blocked`: If no game is earnable and a game state is blocked.
    /// 4. `.completed`: If ALL game states have earned drops.
    @MainActor
    public static func resolve(for miner: MinerManager.ManagedMiner) -> PrimaryState {
        // Global auth block takes precedence
        if miner.needsAuth {
            return .blocked(reasons: [.accountNotLinked])
        }

        // A manual stream override pins this running miner to one streamer regardless of game or
        // campaign, so it takes precedence over normal game-state resolution.
        if let overrideLogin = miner.streamOverrideLogin, miner.isRunning {
            return .overriding(login: overrideLogin, progress: overrideProgress(for: miner))
        }

        // Empty prioritised list → idle/ready with no warnings
        if miner.priorityGames.isEmpty {
            return .ready
        }

        let gameStates = miner.gameStates

        // No games at all → derive from raw miner state
        guard !gameStates.isEmpty else {
            return fallbackResolve(for: miner)
        }

        let resolved = ResolvedPrimaryState(gameStates: gameStates)
        guard let primary = resolved.resolved else {
            return fallbackResolve(for: miner)
        }

        switch primary.state {
        case .blocked:
            switch primary.reason {
            case .notLinked:
                return .blocked(reasons: [.accountNotLinked])
            case .noCampaign, .noEligibleCampaign, .campaignExpired:
                return .blocked(reasons: [.noEligibleCampaign])
            case .noLiveStreams:
                return .blocked(reasons: [.noLiveStreams])
            case .noDropsAvailable:
                return .blocked(reasons: [.noEligibleCampaign])
            case .none:
                return .blocked(reasons: [.noEligibleCampaign])
            }

        case .watching:
            // Map to .mining with progress details
            if let campaign = miner.allCampaigns.first(where: { $0.id == primary.campaignId }),
               let activeDrop = campaign.drops.first(where: { !$0.isClaimed }) {
                let dropState = miner.stateStore?.dropStates.first { $0.dropId == activeDrop.id }
                let currentMinutes = max(dropState?.progressMinutes ?? 0, activeDrop.progress?.currentMinutes ?? 0)
                let requiredMinutes = max(dropState?.requiredMinutes ?? 0, activeDrop.progress?.requiredMinutes ?? activeDrop.requiredMinutes)

                if currentMinutes < requiredMinutes {
                    let fraction = requiredMinutes > 0 ? Double(currentMinutes) / Double(requiredMinutes) : 0
                    let progress = MiningProgress(
                        gameName: campaign.game.name,
                        campaignName: campaign.name,
                        dropName: activeDrop.progress?.dropName.isEmpty == false ? activeDrop.progress?.dropName ?? activeDrop.name : activeDrop.name,
                        progressFraction: min(1.0, max(0.0, fraction)),
                        minutesRemaining: max(0, requiredMinutes - currentMinutes)
                    )
                    return .mining(progress: progress)
                }
            }
            // Watching but drop complete → ready
            return .ready

        case .idle:
            // All games have no drops available (all claimed) → completed
            if gameStates.allSatisfy({ $0.reason == .noDropsAvailable }) {
                return .completed
            }
            // Any idle game with an available campaign → ready
            let hasEarnable = gameStates.contains { gs in
                gs.isIdle && gs.reason == .none
            }
            if hasEarnable {
                return .ready
            }
            return .blocked(reasons: [.noEligibleCampaign])
        }
    }

    /// Drop progress for an override session that happens to be mining an eligible campaign.
    /// Returns nil for a pure "watch only" override (no mineable drop on the channel).
    @MainActor
    private static func overrideProgress(for miner: MinerManager.ManagedMiner) -> MiningProgress? {
        guard let campaignId = miner.currentCampaignId,
              let campaign = miner.allCampaigns.first(where: { $0.id == campaignId }),
              let activeDrop = campaign.drops.first(where: { !$0.isClaimed }) else {
            return nil
        }
        let dropState = miner.stateStore?.dropStates.first { $0.dropId == activeDrop.id }
        let currentMinutes = max(dropState?.progressMinutes ?? 0, activeDrop.progress?.currentMinutes ?? 0)
        let requiredMinutes = max(dropState?.requiredMinutes ?? 0, activeDrop.progress?.requiredMinutes ?? activeDrop.requiredMinutes)
        guard requiredMinutes > 0, currentMinutes < requiredMinutes else { return nil }
        let fraction = Double(currentMinutes) / Double(requiredMinutes)
        return MiningProgress(
            gameName: campaign.game.name,
            campaignName: campaign.name,
            dropName: activeDrop.progress?.dropName.isEmpty == false ? activeDrop.progress?.dropName ?? activeDrop.name : activeDrop.name,
            progressFraction: min(1.0, max(0.0, fraction)),
            minutesRemaining: max(0, requiredMinutes - currentMinutes)
        )
    }

    /// Legacy fallback: resolves from raw miner fields when no game-state list is available.
    @MainActor
    private static func fallbackResolve(for miner: MinerManager.ManagedMiner) -> PrimaryState {
        // Filter out irrelevant campaigns (no drops) AND hard exclude "Just Chatting"
        let relevantCampaigns = miner.allCampaigns.filter { campaign in
            if campaign.drops.isEmpty { return false }
            if campaign.isLikelyInternalTestCampaign { return false }
            
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
            Logger.engine.info("needsAuth=true → .blocked(.accountNotLinked)")
            return .blocked(reasons: [.accountNotLinked])
        }
        
        // 1b. A prioritised, active campaign can still be attempted while its
        // external game account is unlinked. Keep the link warning as a blocked
        // presentation only when there is no linked earnable work to fall back to.
        let priorityGamesLower = Set(miner.priorityGames.map { $0.lowercased() })
        let blockedPriority = relevantCampaigns.filter { campaign in
            campaign.isTimeActive &&
                !campaign.isAccountConnected &&
                priorityGamesLower.contains(campaign.gameName.lowercased()) &&
                campaign.drops.contains { !isEarned($0) }
        }
        let hasEarnableWork = relevantCampaigns.contains { campaign in
            campaign.isTimeActive && campaign.isAccountConnected && campaign.drops.contains { !isEarned($0) }
        }
        if !blockedPriority.isEmpty && !hasEarnableWork {
            Logger.engine.info("prioritised campaign(s) unlinked and no other work → .blocked(.accountNotLinked)")
            return .blocked(reasons: [.accountNotLinked])
        }

        // 1c. No Live Streams Block (Stable Engine State)
        if miner.status == .waitingForStream {
            Logger.engine.info("status=.waitingForStream → .blocked(.noLiveStreams)")
            return .blocked(reasons: [.noLiveStreams])
        }

        // 1d. Eligibility Block (No campaigns at all)
        if relevantCampaigns.isEmpty {
            Logger.engine.info("no campaigns with drops → .blocked(.noEligibleCampaign)")
            return .blocked(reasons: [.noEligibleCampaign])
        }
        
        // If NO campaigns are either active or already completed, we are blocked (e.g. all upcoming)
        let hasActiveOrComplete = relevantCampaigns.contains { campaign in
            campaign.isTimeActive || campaign.drops.allSatisfy { isEarned($0) }
        }
        if !hasActiveOrComplete {
            Logger.engine.info("all \(relevantCampaigns.count) campaigns are upcoming/inactive → .blocked(.noEligibleCampaign)")
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
                let currentMinutes = max(dropState?.progressMinutes ?? 0, activeDrop.progress?.currentMinutes ?? 0)
                let requiredMinutes = max(dropState?.requiredMinutes ?? 0, activeDrop.progress?.requiredMinutes ?? activeDrop.requiredMinutes)
                
                // Only return .mining if there is actual progress left to earn.
                if currentMinutes < requiredMinutes {
                    let fraction = requiredMinutes > 0 ? Double(currentMinutes) / Double(requiredMinutes) : 0
                    
                    let progress = MiningProgress(
                        gameName: campaign.game.name,
                        campaignName: campaign.name,
                        dropName: activeDrop.progress?.dropName.isEmpty == false ? activeDrop.progress?.dropName ?? activeDrop.name : activeDrop.name,
                        progressFraction: min(1.0, max(0.0, fraction)),
                        minutesRemaining: max(0, requiredMinutes - currentMinutes)
                    )
                    Logger.engine.info("status=.watching campaign=\(campaign.name) drop=\(activeDrop.name) progress=\(String(format: "%.2f", fraction)) → .mining")
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
            Logger.engine.info("hasEarnable=true → .ready")
            return .ready
        }
        
        // 4. Completed Check (Lowest Priority)
        // Task 1.4: "all drops earned (progress.isComplete == true for all) -> .completed"
        // Task 3.3: "completed = earnedDrops == totalDrops"
        let allEarned = relevantCampaigns.allSatisfy { campaign in
            campaign.drops.allSatisfy { isEarned($0) }
        }
        
        if allEarned {
            Logger.engine.info("all drops across \(relevantCampaigns.count) campaigns earned → .completed")
            return .completed
        }
        
        // 5. Fallback (Scanning/Idle/Claiming)
        Logger.engine.info("fallback → .ready")
        return .ready
    }

    // MARK: - Private Helpers

    private static func isEarned(_ drop: Drop) -> Bool {
        // Task 3: True completion only when claimed. Prevent false "completed"
        // when drops are watched but not yet confirmed by Twitch.
        drop.isClaimed
    }
}
