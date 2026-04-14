import XCTest
@testable import SwiftMinerCore

@MainActor
final class PrimaryStateResolverTests: XCTestCase {

    // MARK: - Helper Methods

    private func createMiner(
        status: MinerManager.MinerStatus = .idle,
        needsAuth: Bool = false,
        allCampaigns: [Campaign] = [],
        currentCampaignId: String? = nil
    ) -> MinerManager.ManagedMiner {
        MinerManager.ManagedMiner(
            id: "test-miner",
            accountId: "test-account",
            username: "testuser",
            status: status,
            needsAuth: needsAuth,
            currentCampaignId: currentCampaignId,
            allCampaigns: allCampaigns,
            isRunning: true
        )
    }

    private func createCampaign(
        id: String,
        isTimeActive: Bool = true,
        isAccountConnected: Bool = true,
        drops: [Drop] = []
    ) -> Campaign {
        let now = Date()
        return Campaign(
            id: id,
            name: "Campaign \(id)",
            game: Game(id: "game1", name: "Test Game"),
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

    func testBlockedState_AccountNotLinked_CampaignSpecific() {
        let campaign = createCampaign(id: "c1", isAccountConnected: false, drops: [createDrop(id: "d1")])
        let miner = createMiner(allCampaigns: [campaign])
        let state = PrimaryStateResolver.resolve(for: miner)
        XCTAssertEqual(state, .blocked(reasons: [.accountNotLinked]), "Should resolve to .blocked if a campaign is not linked")
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
        let miner = createMiner(status: .waitingForStream, allCampaigns: [campaign])
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

    func testPriority_BlockedOverMining() {
        // 1 campaign blocked, 1 campaign mining.
        // Rule: Blocked > Mining.
        let blockedCampaign = createCampaign(id: "c1", isAccountConnected: false, drops: [createDrop(id: "d1")])
        let miningCampaign = createCampaign(id: "c2", drops: [createDrop(id: "d2")])
        let miner = createMiner(status: .watching, allCampaigns: [blockedCampaign, miningCampaign], currentCampaignId: "c2")
        
        let state = PrimaryStateResolver.resolve(for: miner)
        XCTAssertEqual(state, .blocked(reasons: [.accountNotLinked]))
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

    func testRegression_DisconnectedAccountShowsBlocked() {
        // Bug: "Disconnected campaign account currently shows 'Nothing to earn'"
        // "Must show 'Link Required' instead"
        let campaign = createCampaign(id: "c1", isAccountConnected: false, drops: [createDrop(id: "d1")])
        let miner = createMiner(allCampaigns: [campaign])
        
        let state = PrimaryStateResolver.resolve(for: miner)
        XCTAssertEqual(state, .blocked(reasons: [.accountNotLinked]))
    }

    func testDisconnectedAccountNotBlockedWhenAllClaimed() {
        // Task 3: If all drops are already claimed, disconnected account is irrelevant.
        let drop = createDrop(id: "d1", isClaimed: true)
        let campaign = createCampaign(id: "c1", isAccountConnected: false, drops: [drop])
        let miner = createMiner(allCampaigns: [campaign])
        
        let state = PrimaryStateResolver.resolve(for: miner)
        XCTAssertEqual(state, .completed, "Should be completed when all drops are claimed even if account is disconnected")
    }
}
