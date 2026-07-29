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

        // Smart strategy regularly schedules a campaign for a game that is not on the prioritised
        // list — an earlier deadline wins. Evaluating prioritised games alone meant the miner
        // described itself using games it was not working on, reporting "Drops complete" while it
        // was actively hunting streams for the campaign it had just selected.
        //
        // `currentCampaignId` alone is not enough: the no-channel path clears the watch target
        // before waiting, so in exactly the state this needs to describe it is already nil.
        // `gameChannelAvailability` is the durable record — it survives that cleanup and names
        // the campaign each game was last probed for.
        var gamesToEvaluate = priorityGames
        var scheduledCampaignIds: [String] = []
        if let currentCampaignId = miner.currentCampaignId {
            scheduledCampaignIds.append(currentCampaignId)
        }
        scheduledCampaignIds.append(
            contentsOf: miner.gameChannelAvailability.values
                .sorted { $0.checkedAt > $1.checkedAt }
                .compactMap(\.campaignId)
        )

        for campaignId in scheduledCampaignIds {
            guard let scheduled = miner.allCampaigns.first(where: { $0.id == campaignId }) else { continue }
            let scheduledName = scheduled.gameName.lowercased()
            let scheduledId = scheduled.game.id.lowercased()
            let alreadyCovered = gamesToEvaluate.contains {
                let key = $0.lowercased()
                return key == scheduledName || key == scheduledId
            }
            if !alreadyCovered {
                gamesToEvaluate.append(scheduled.gameName)
            }
        }

        var states: [MinerGameState] = []
        var seenGames = Set<String>()

        for priorityGame in gamesToEvaluate {
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
                // Account linking is surfaced separately as a warning. It must not
                // turn a prioritised game into a blocked scheduling state.
                states.append(MinerGameState(
                    minerId: miner.id,
                    gameId: gameId,
                    gameName: gameName,
                    state: .idle,
                    reason: .noEligibleCampaign
                ))
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

                // Expiry remains a real scheduling block. Missing game-account
                // linkage does not: a prioritised campaign is still attempted when
                // Twitch exposes usable drops.
                if !campaign.isActive {
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
