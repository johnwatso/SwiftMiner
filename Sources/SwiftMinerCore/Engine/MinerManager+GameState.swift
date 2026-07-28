// Per-miner, per-game state evaluation for MinerManager. Split from
// MinerManager.swift; same class, same @MainActor isolation.
import Foundation

extension MinerManager {
    // MARK: - Per-Miner, Per-Game State Evaluation (MinerGameState Refactor)

    /// Evaluate the per-game state for a miner.
    /// Iterates over `priorityGames` to ensure every prioritised game produces a state,
    /// even when no campaigns are returned for that game.
    @MainActor
    public static func evaluateGameStates(for miner: ManagedMiner, priorityGames: [String]) -> [MinerGameState] {
        if priorityGames.isEmpty { return [] }

        var states: [MinerGameState] = []
        var seenGames = Set<String>()

        for priorityGame in priorityGames {
            let gameKey = priorityGame.lowercased()
            guard seenGames.insert(gameKey).inserted else { continue }

            // Gather all campaigns for this prioritised game (used for linkage check)
            let campaignsForGame = miner.allCampaigns.filter {
                $0.gameName.lowercased() == gameKey || $0.game.id.lowercased() == gameKey
            }

            // 1. Identify the stable game metadata
            let gameId = campaignsForGame.first?.game.id ?? gameKey
            let gameName = campaignsForGame.first?.game.name ?? priorityGame

            // 2. Filter out irrelevant campaigns (no drops, Just Chatting)
            let relevant = campaignsForGame.filter { campaign in
                if campaign.drops.isEmpty { return false }
                if campaign.isLikelyInternalTestCampaign { return false }
                let name = campaign.game.name.trimmingCharacters(in: .whitespacesAndNewlines)
                let id = campaign.game.id.trimmingCharacters(in: .whitespacesAndNewlines)
                if name.localizedCaseInsensitiveCompare("Just Chatting") == .orderedSame || id == "509658" {
                    return false
                }
                return true
            }

            if relevant.isEmpty {
                // Link-state warnings still matter for prioritised games even if
                // Twitch did not return an otherwise relevant campaign.
                let isNotLinked = !campaignsForGame.isEmpty && campaignsForGame.contains { !$0.isAccountConnected }

                if isNotLinked {
                    states.append(MinerGameState(
                        minerId: miner.id,
                        gameId: gameId,
                        gameName: gameName,
                        state: .blocked,
                        reason: .notLinked
                    ))
                } else {
                    states.append(MinerGameState(
                        minerId: miner.id,
                        gameId: gameId,
                        gameName: gameName,
                        state: .idle,
                        reason: .noEligibleCampaign
                    ))
                }
                continue
            }

            var activeCampaign: Campaign?
            var blockedReason: MinerGameStateReason?
            var nothingLeftToMine = true

            for campaign in relevant {
                // Subscription-gated drops are never mineable, so a campaign left with
                // only those reads the same as one that is fully claimed.
                if campaign.hasWatchableWorkRemaining {
                    nothingLeftToMine = false
                } else {
                    continue
                }

                // Missing game-account linkage is a warning, not a hard block,
                // when Twitch still exposes usable drops for a prioritised game.
                if campaign.canAttemptMining {
                    if activeCampaign == nil {
                        activeCampaign = campaign
                    }
                }

                // Collect blocking reasons (scan all campaigns; blocked wins)
                if campaign.isTimeActive && !campaign.isAccountConnected {
                    if blockedReason == nil { blockedReason = .notLinked }
                } else if !campaign.isActive {
                    if blockedReason == nil { blockedReason = .campaignExpired }
                }
            }

            if nothingLeftToMine {
                states.append(MinerGameState(
                    minerId: miner.id,
                    gameId: gameId,
                    gameName: gameName,
                    state: .idle,
                    reason: .noDropsAvailable
                ))
                continue
            }

            // Determine session context for this game
            let isWatchingThisGame = miner.status == .watching
                && relevant.contains(where: { $0.id == miner.currentCampaignId })
            let isWaitingForStream = miner.status == .waitingForStream
                && relevant.contains(where: { $0.id == miner.currentCampaignId })

            if isWaitingForStream, let campaignId = miner.currentCampaignId {
                states.append(MinerGameState(
                    minerId: miner.id,
                    gameId: gameId,
                    gameName: gameName,
                    state: .blocked,
                    reason: .noLiveStreams,
                    campaignId: campaignId
                ))
            } else if isWatchingThisGame, let campaign = activeCampaign ?? relevant.first {
                states.append(MinerGameState(
                    minerId: miner.id,
                    gameId: gameId,
                    gameName: gameName,
                    state: .watching,
                    reason: .none,
                    campaignId: campaign.id
                ))
            } else if let campaign = activeCampaign {
                let waitingForStream = miner.status == .waitingForStream
                states.append(MinerGameState(
                    minerId: miner.id,
                    gameId: gameId,
                    gameName: gameName,
                    state: waitingForStream ? .blocked : .idle,
                    reason: waitingForStream ? .noLiveStreams : .none,
                    campaignId: campaign.id
                ))
            } else if let reason = blockedReason {
                states.append(MinerGameState(
                    minerId: miner.id,
                    gameId: gameId,
                    gameName: gameName,
                    state: .blocked,
                    reason: reason
                ))
            } else {
                states.append(MinerGameState(
                    minerId: miner.id,
                    gameId: gameId,
                    gameName: gameName,
                    state: .idle,
                    reason: .noEligibleCampaign
                ))
            }
        }

        return states
    }
}
