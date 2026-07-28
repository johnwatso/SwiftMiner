import XCTest
@testable import SwiftMinerCore

@MainActor
final class PrimaryStateResolverTests: XCTestCase {

    // MARK: - Helper Methods

    private func createMiner(
        status: MinerManager.MinerStatus = .idle,
        needsAuth: Bool = false,
        allCampaigns: [Campaign] = [],
        currentCampaignId: String? = nil,
        priorityGames: [String] = ["Test Game"]
    ) -> MinerManager.ManagedMiner {
        MinerManager.ManagedMiner(
            id: "test-miner",
            accountId: "test-account",
            username: "testuser",
            status: status,
            needsAuth: needsAuth,
            currentCampaignId: currentCampaignId,
            allCampaigns: allCampaigns,
            isRunning: true,
            priorityGames: priorityGames
        )
    }

    private func createCampaign(
        id: String,
        gameId: String = "game1",
        gameName: String = "Test Game",
        isTimeActive: Bool = true,
        isAccountConnected: Bool = true,
        drops: [Drop] = []
    ) -> Campaign {
        let now = Date()
        return Campaign(
            id: id,
            name: "Campaign \(id)",
            game: Game(id: gameId, name: gameName),
            startDate: isTimeActive ? now.addingTimeInterval(-3600) : now.addingTimeInterval(3600),
            endDate: isTimeActive ? now.addingTimeInterval(3600) : now.addingTimeInterval(7200),
            drops: drops,
            isAccountConnected: isAccountConnected
        )
    }

    private func createDrop(id: String, isClaimed: Bool = false, isComplete: Bool = false) -> Drop {
        var drop = Drop(id: id, name: "Drop \(id)", requiredMinutes: 60, isClaimed: isClaimed)
        if isComplete {
            drop.progress = Progress(dropId: id, campaignId: "c1", currentMinutes: 60, requiredMinutes: 60)
        }
        return drop
    }

    // MARK: - Test Cases

    func testBlockedState_AccountNotLinked_Global() {
        let miner = createMiner(needsAuth: true)
        let state = PrimaryStateResolver.resolve(for: miner)
        XCTAssertEqual(state, .blocked(reasons: [.accountNotLinked]))
    }

    func testUnlinkedCampaignWithUsableDropsIsReadyToAttempt() {
        let campaign = createCampaign(id: "c1", isAccountConnected: false, drops: [createDrop(id: "d1")])
        let miner = createMiner(allCampaigns: [campaign])
        let state = PrimaryStateResolver.resolve(for: miner)
        XCTAssertEqual(state, .ready, "Missing game-account linkage should warn, not block, when Twitch exposes usable drops")
    }

    func testBlockedState_NoEligibleCampaign_Empty() {
        let miner = createMiner(allCampaigns: [])
        let state = PrimaryStateResolver.resolve(for: miner)
        XCTAssertEqual(state, .blocked(reasons: [.noEligibleCampaign]))
    }

    func testBlockedState_NoEligibleCampaign_UpcomingOnly() {
        let campaign = createCampaign(id: "c1", isTimeActive: false, drops: [createDrop(id: "d1")])
        let miner = createMiner(allCampaigns: [campaign])
        let state = PrimaryStateResolver.resolve(for: miner)
        XCTAssertEqual(state, .blocked(reasons: [.noEligibleCampaign]))
    }

    func testBlockedState_NoLiveStreams() {
        let campaign = createCampaign(id: "c1", isAccountConnected: true, drops: [createDrop(id: "d1")])
        let miner = createMiner(status: .waitingForStream, allCampaigns: [campaign], currentCampaignId: "c1")
        let state = PrimaryStateResolver.resolve(for: miner)
        XCTAssertEqual(state, .blocked(reasons: [.noLiveStreams]))
    }

    func testMiningState() {
        let drop = createDrop(id: "d1")
        let campaign = createCampaign(id: "c1", drops: [drop])
        let miner = createMiner(status: .watching, allCampaigns: [campaign], currentCampaignId: "c1")
        
        let state = PrimaryStateResolver.resolve(for: miner)
        
        if case .mining(let progress) = state {
            XCTAssertEqual(progress.campaignName, "Campaign c1")
            XCTAssertEqual(progress.dropName, "Drop d1")
        } else {
            XCTFail("Should be in .mining state, got \(state)")
        }
    }

    func testReadyState_EligibleButNotWatching() {
        let campaign = createCampaign(id: "c1", drops: [createDrop(id: "d1")])
        let miner = createMiner(status: .idle, allCampaigns: [campaign])
        
        let state = PrimaryStateResolver.resolve(for: miner)
        XCTAssertEqual(state, .ready)
    }

    func testCompletedState_AllDropsClaimed() {
        let drop = createDrop(id: "d1", isClaimed: true)
        let campaign = createCampaign(id: "c1", drops: [drop])
        let miner = createMiner(allCampaigns: [campaign])
        
        let state = PrimaryStateResolver.resolve(for: miner)
        XCTAssertEqual(state, .completed)
    }

    func testReadyState_EarnedButUnclaimed() {
        // Task 3: True completion only when claimed.
        // Drop is progress-complete (earned) but NOT claimed.
        // Should be .ready so the claimer can process it, NOT .completed.
        var drop = createDrop(id: "d1", isClaimed: false)
        drop.progress = Progress(dropId: "d1", campaignId: "c1", currentMinutes: 60, requiredMinutes: 60)
        XCTAssertTrue(drop.isClaimable)
        
        let campaign = createCampaign(id: "c1", drops: [drop])
        let miner = createMiner(allCampaigns: [campaign])
        
        let state = PrimaryStateResolver.resolve(for: miner)
        XCTAssertEqual(state, .ready, "Should be ready when drops are earned but not yet claimed")
    }

    func testPriority_MiningOverBlocked() {
        // 1 campaign blocked, 1 campaign mining.
        // Rule: an account that is successfully mining should not present as blocked.
        let blockedCampaign = createCampaign(id: "c1", isAccountConnected: false, drops: [createDrop(id: "d1")])
        let miningCampaign = createCampaign(id: "c2", drops: [createDrop(id: "d2")])
        let miner = createMiner(status: .watching, allCampaigns: [blockedCampaign, miningCampaign], currentCampaignId: "c2")
        
        let state = PrimaryStateResolver.resolve(for: miner)
        if case .mining = state {} else {
            XCTFail("Should be .mining")
        }
    }

    func testPriority_UnlinkedAttemptablePriorityCanWinOverLinkedLowerPriority() {
        let blockedCampaign = createCampaign(
            id: "c1",
            gameId: "blocked-game",
            gameName: "Blocked Game",
            isAccountConnected: false,
            drops: [createDrop(id: "d1")]
        )
        let earnableCampaign = createCampaign(
            id: "c2",
            gameId: "earnable-game",
            gameName: "Earnable Game",
            drops: [createDrop(id: "d2")]
        )
        let miner = createMiner(
            allCampaigns: [blockedCampaign, earnableCampaign],
            priorityGames: ["Blocked Game", "Earnable Game"]
        )

        XCTAssertEqual(miner.primaryState, .ready)
        XCTAssertEqual(miner.resolvedPrimaryState?.resolved?.gameName, "Blocked Game")
        XCTAssertEqual(miner.resolvedPrimaryState?.resolved?.state, .idle)
        XCTAssertEqual(miner.resolvedPrimaryState?.resolved?.reason, MinerGameStateReason.none)
    }

    func testPriority_MiningOverReady() {
        // 1 campaign mining, 1 campaign ready.
        let miningCampaign = createCampaign(id: "c1", drops: [createDrop(id: "d1")])
        let readyCampaign = createCampaign(id: "c2", drops: [createDrop(id: "d2")])
        let miner = createMiner(status: .watching, allCampaigns: [miningCampaign, readyCampaign], currentCampaignId: "c1")
        
        let state = PrimaryStateResolver.resolve(for: miner)
        if case .mining = state {} else {
            XCTFail("Should be .mining")
        }
    }

    func testDisconnectedAccountWithUsableDropsDoesNotBlockMiningAttempt() {
        let campaign = createCampaign(id: "c1", isAccountConnected: false, drops: [createDrop(id: "d1")])
        let miner = createMiner(allCampaigns: [campaign])
        
        let state = PrimaryStateResolver.resolve(for: miner)
        XCTAssertEqual(state, .ready)
    }

    func testDisconnectedAccountNotBlockedWhenAllClaimed() {
        // Task 3: If all drops are already claimed, disconnected account is irrelevant.
        let drop = createDrop(id: "d1", isClaimed: true)
        let campaign = createCampaign(id: "c1", isAccountConnected: false, drops: [drop])
        let miner = createMiner(allCampaigns: [campaign])
        
        let state = PrimaryStateResolver.resolve(for: miner)
        XCTAssertEqual(state, .completed, "Should be completed when all drops are claimed even if account is disconnected")
    }

    // MARK: - MinerGameState Model Tests

    func testEvaluateGameStates_WatchingRequiresStatusAndCampaignMatch() {
        let campaign = createCampaign(id: "c1", drops: [createDrop(id: "d1")])

        // Status is watching but currentCampaignId does NOT match → idle
        let idleMiner = createMiner(status: .watching, allCampaigns: [campaign], currentCampaignId: "other")
        let idleStates = MinerManager.evaluateGameStates(for: idleMiner, priorityGames: idleMiner.priorityGames)
        XCTAssertEqual(idleStates.first?.state, .idle)

        // Status is watching and currentCampaignId matches → watching
        let watchingMiner = createMiner(status: .watching, allCampaigns: [campaign], currentCampaignId: "c1")
        let watchingStates = MinerManager.evaluateGameStates(for: watchingMiner, priorityGames: watchingMiner.priorityGames)
        XCTAssertEqual(watchingStates.first?.state, .watching)
    }

    func testEvaluateGameStates_WatchingWinsOverBlockedWithinSameGame() {
        let blockedCampaign = createCampaign(id: "c1", isAccountConnected: false, drops: [createDrop(id: "d1")])
        let miningCampaign = createCampaign(id: "c2", drops: [createDrop(id: "d2")])
        let miner = createMiner(status: .watching, allCampaigns: [blockedCampaign, miningCampaign], currentCampaignId: "c2")

        let states = MinerManager.evaluateGameStates(for: miner, priorityGames: miner.priorityGames)
        XCTAssertEqual(states.count, 1) // same game
        XCTAssertEqual(states.first?.state, .watching)
        XCTAssertEqual(states.first?.reason, MinerGameStateReason.none)
    }

    func testResolvedPrimaryState_PriorityWatchingOverBlockedOverIdle() {
        let states = [
            MinerGameState(minerId: "m1", gameId: "g1", gameName: "Game 1", state: .idle, reason: .none),
            MinerGameState(minerId: "m1", gameId: "g2", gameName: "Game 2", state: .watching, reason: .none),
            MinerGameState(minerId: "m1", gameId: "g3", gameName: "Game 3", state: .blocked, reason: .notLinked)
        ]
        let resolved = ResolvedPrimaryState(gameStates: states)
        XCTAssertEqual(resolved.resolved?.gameId, "g2")
        XCTAssertEqual(resolved.resolved?.state, .watching)
    }

    func testEvaluateGameStates_WaitingForStreamScopedToGame() {
        let campaign = createCampaign(id: "c1", isAccountConnected: true, drops: [createDrop(id: "d1")])
        let miner = createMiner(status: .waitingForStream, allCampaigns: [campaign], currentCampaignId: "c1")

        let states = MinerManager.evaluateGameStates(for: miner, priorityGames: miner.priorityGames)
        XCTAssertEqual(states.first?.state, .blocked)
        XCTAssertEqual(states.first?.reason, .noLiveStreams)
        XCTAssertEqual(states.first?.campaignId, "c1")
    }

    func testManagedMiner_GameStatesAndResolvedPrimaryState() {
        let campaign = createCampaign(id: "c1", drops: [createDrop(id: "d1")])
        let miner = createMiner(status: .watching, allCampaigns: [campaign], currentCampaignId: "c1")

        XCTAssertEqual(miner.gameStates.count, 1)
        XCTAssertEqual(miner.gameStates.first?.state, .watching)
        XCTAssertEqual(miner.resolvedPrimaryState?.resolved?.state, .watching)
    }

    // MARK: - Prioritised Games Filtering Tests

    func testEmptyPriorityGames_ResolvesToReady() {
        let campaign = createCampaign(id: "c1", drops: [createDrop(id: "d1")])
        let miner = createMiner(allCampaigns: [campaign], priorityGames: [])

        XCTAssertTrue(miner.gameStates.isEmpty, "No game states should be produced when priority list is empty")
        XCTAssertEqual(miner.primaryState, .ready, "Empty priority list should resolve to ready (idle)")
    }

    func testNonPrioritisedCampaign_NoGameStateOrWarning() {
        let campaign = createCampaign(id: "c1", drops: [createDrop(id: "d1")])
        let miner = createMiner(allCampaigns: [campaign], priorityGames: ["Other Game"])

        // The non-prioritised campaign should not appear in the game-state list
        let hasTestGameState = miner.gameStates.contains { $0.gameName == "Test Game" }
        XCTAssertFalse(hasTestGameState, "Non-prioritised campaign should not produce a MinerGameState")

        // The prioritised game "Other Game" has no campaigns, so it produces an idle state
        XCTAssertEqual(miner.gameStates.count, 1)
        XCTAssertEqual(miner.gameStates.first?.gameName, "Other Game")
        XCTAssertEqual(miner.gameStates.first?.state, .idle)
        XCTAssertEqual(miner.gameStates.first?.reason, .noEligibleCampaign)
    }

    func testPrioritisedCampaign_ByGameId() {
        let campaign = createCampaign(id: "c1", drops: [createDrop(id: "d1")])
        let miner = createMiner(status: .watching, allCampaigns: [campaign], currentCampaignId: "c1", priorityGames: ["game1"])

        XCTAssertEqual(miner.gameStates.count, 1, "Should match prioritised game by ID")
        XCTAssertEqual(miner.gameStates.first?.state, .watching)
    }

    func testPrioritisedGame_ZeroCampaigns_ProducesIdleNoEligibleCampaign() {
        let miner = createMiner(allCampaigns: [], priorityGames: ["Test Game"])

        XCTAssertEqual(miner.gameStates.count, 1, "Prioritised game with no campaigns must still produce a MinerGameState")
        let state = miner.gameStates.first
        XCTAssertEqual(state?.state, .idle)
        XCTAssertEqual(state?.reason, .noEligibleCampaign)
        XCTAssertEqual(state?.gameName, "Test Game")
    }

    func testPrioritisedGame_NotLinkedWithUsableDrops_ProducesIdleAttemptableState() {
        let campaign = createCampaign(id: "c1", isAccountConnected: false, drops: [createDrop(id: "d1")])
        let miner = createMiner(allCampaigns: [campaign], priorityGames: ["Test Game"])

        XCTAssertEqual(miner.gameStates.count, 1)
        let state = miner.gameStates.first
        XCTAssertEqual(state?.state, .idle)
        XCTAssertEqual(state?.reason, MinerGameStateReason.none)
        XCTAssertEqual(state?.campaignId, "c1")
    }

    func testPrioritisedGame_NotLinkedEvenIfNoDrops_ProducesBlocked() {
        // Campaign exists but has no drops (relevant.isEmpty is true)
        // But it is NOT linked.
        let campaign = createCampaign(id: "c1", isAccountConnected: false, drops: [])
        let miner = createMiner(allCampaigns: [campaign], priorityGames: ["Test Game"])

        XCTAssertEqual(miner.gameStates.count, 1)
        let state = miner.gameStates.first
        XCTAssertEqual(state?.state, .blocked)
        XCTAssertEqual(state?.reason, .notLinked)
    }

    // MARK: - Scheduler-selected (non-prioritised) game

    func testScheduledNonPrioritisedGameProducesItsOwnState() {
        // Smart strategy picks an earlier-ending campaign for a game the user did not prioritise.
        let scheduled = createCampaign(
            id: "esports",
            gameId: "brawlhalla",
            gameName: "Brawlhalla",
            drops: [createDrop(id: "d1")]
        )
        let miner = createMiner(
            status: .waitingForStream,
            allCampaigns: [scheduled],
            currentCampaignId: "esports",
            priorityGames: ["THE FINALS"]
        )

        let states = MinerManager.evaluateGameStates(for: miner, priorityGames: miner.priorityGames)

        XCTAssertEqual(states.count, 2, "The prioritised game and the game actually scheduled must both be evaluated")
        let scheduledState = states.first { $0.gameName == "Brawlhalla" }
        XCTAssertEqual(scheduledState?.state, .blocked)
        XCTAssertEqual(scheduledState?.reason, .noLiveStreams)
        XCTAssertEqual(scheduledState?.campaignId, "esports")
    }

    func testWaitingOnScheduledGameIsNotReportedAsDropsComplete() {
        // The prioritised game has nothing watchable left (its only reward is subscription-gated),
        // while the miner is actively waiting for a stream for the campaign it did schedule.
        // Reporting the miner as finished here is what hid real work behind "Drops complete".
        var gatedDrop = Drop(id: "gated", name: "Gated Reward", requiredMinutes: 0, requiredSubs: 1)
        gatedDrop.progress = nil
        let gated = createCampaign(
            id: "gated-campaign",
            gameId: "finals",
            gameName: "THE FINALS",
            drops: [gatedDrop]
        )
        let scheduled = createCampaign(
            id: "esports",
            gameId: "brawlhalla",
            gameName: "Brawlhalla",
            drops: [createDrop(id: "d1")]
        )
        let miner = createMiner(
            status: .waitingForStream,
            allCampaigns: [gated, scheduled],
            currentCampaignId: "esports",
            priorityGames: ["THE FINALS"]
        )

        XCTAssertEqual(miner.resolvedPrimaryState?.resolved?.gameName, "Brawlhalla")
        XCTAssertEqual(miner.statusLabel, "Waiting — No live stream")
    }

    func testScheduledGameAlreadyPrioritisedIsNotDuplicated() {
        let campaign = createCampaign(id: "c1", drops: [createDrop(id: "d1")])
        let miner = createMiner(
            status: .waitingForStream,
            allCampaigns: [campaign],
            currentCampaignId: "c1",
            priorityGames: ["Test Game"]
        )

        let states = MinerManager.evaluateGameStates(for: miner, priorityGames: miner.priorityGames)
        XCTAssertEqual(states.count, 1)
    }
}
