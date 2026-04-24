import XCTest
@testable import SwiftMinerCore
@testable import SwiftMiner

@MainActor
final class MinerActivitySnapshotTests: XCTestCase {

    private func makeMiner(
        status: MinerManager.MinerStatus = .idle,
        campaigns: [Campaign],
        currentCampaignId: String? = nil,
        priorityGames: [String] = ["Test Game"]
    ) -> MinerManager.ManagedMiner {
        MinerManager.ManagedMiner(
            id: "miner-1",
            accountId: "account-1",
            username: "tester",
            status: status,
            currentCampaignId: currentCampaignId,
            allCampaigns: campaigns,
            isRunning: true,
            priorityGames: priorityGames
        )
    }

    private func makeCampaign(
        id: String,
        gameId: String = "game-1",
        gameName: String = "Test Game",
        isAccountConnected: Bool,
        drops: [Drop] = [Drop(id: "drop-1", name: "Drop 1", requiredMinutes: 60)]
    ) -> Campaign {
        let now = Date()
        return Campaign(
            id: id,
            name: "Campaign \(id)",
            game: Game(id: gameId, name: gameName),
            startDate: now.addingTimeInterval(-3600),
            endDate: now.addingTimeInterval(3600),
            drops: drops,
            isAccountConnected: isAccountConnected
        )
    }

    private func resolveSnapshot(for miner: MinerManager.ManagedMiner) -> MinerActivitySnapshot {
        MinerActivitySnapshot.resolve(
            for: miner,
            priorityGames: ["Test Game"],
            excludedGames: [],
            strategy: .prioritiseSelected,
            includesBadgeAndEmoteCampaigns: false
        )
    }

    func testUpNextDoesNotShowUnlinkedCampaign() {
        let campaign = makeCampaign(id: "unlinked", isAccountConnected: false)
        let miner = makeMiner(campaigns: [campaign])

        let snapshot = resolveSnapshot(for: miner)

        XCTAssertNil(snapshot.upNext)
        XCTAssertTrue(snapshot.now.requiresAccountLink)
    }

    func testUpNextShowsLinkedEligibleCampaign() {
        let campaign = makeCampaign(id: "linked", isAccountConnected: true)
        let miner = makeMiner(campaigns: [campaign])

        let snapshot = resolveSnapshot(for: miner)

        XCTAssertEqual(snapshot.upNext?.campaignId, "linked")
        XCTAssertFalse(snapshot.upNext?.requiresAccountLink ?? true)
    }

    func testNewIdleAndBlockedStatusesSurfaceInSnapshot() {
        let idleMiner = makeMiner(
            status: .idleNoEligibleCampaigns,
            campaigns: [],
            priorityGames: []
        )
        let blockedMiner = makeMiner(
            status: .blockedAccountNotLinked,
            campaigns: [],
            priorityGames: []
        )

        let idleSnapshot = resolveSnapshot(for: idleMiner)
        let blockedSnapshot = resolveSnapshot(for: blockedMiner)

        XCTAssertEqual(idleSnapshot.statusText, "Idle — No eligible campaigns")
        XCTAssertEqual(idleSnapshot.now.title, "Idle — No eligible campaigns")
        XCTAssertNil(idleSnapshot.upNext)

        XCTAssertEqual(blockedSnapshot.statusText, "Blocked — Account not linked")
        XCTAssertEqual(blockedSnapshot.now.title, "Blocked — Account not linked")
        XCTAssertNil(blockedSnapshot.upNext)
    }
}
