import XCTest
@testable import SwiftMinerCore
@testable import SwiftMiner

@MainActor
final class MinerActivitySnapshotTests: XCTestCase {

    private func makeMiner(
        status: MinerManager.MinerStatus = .idle,
        campaigns: [Campaign],
        currentCampaignId: String? = nil,
        priorityGames: [String] = ["Test Game"],
        workerState: MinerWorkerState = .running,
        isHealthy: Bool = true,
        isStalled: Bool = false
    ) -> MinerManager.ManagedMiner {
        MinerManager.ManagedMiner(
            id: "miner-1",
            accountId: "account-1",
            username: "tester",
            status: status,
            currentCampaignId: currentCampaignId,
            allCampaigns: campaigns,
            isRunning: true,
            priorityGames: priorityGames,
            workerState: workerState,
            isHealthy: isHealthy,
            isStalled: isStalled
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

    func testUpNextCanShowUnlinkedAttemptableCampaign() {
        let campaign = makeCampaign(id: "unlinked", isAccountConnected: false)
        let miner = makeMiner(campaigns: [campaign])

        let snapshot = resolveSnapshot(for: miner)

        XCTAssertEqual(snapshot.upNext?.campaignId, "unlinked")
        XCTAssertFalse(snapshot.upNext?.requiresAccountLink ?? true)
    }

    func testUpNextHidesUnlinkedNonPrioritisedCampaign() {
        // An unlinked campaign whose game is NOT prioritised for this miner must not
        // surface — otherwise another miner's prioritised game leaks in here.
        let campaign = makeCampaign(id: "unlinked-other", gameId: "game-2", gameName: "Other Game", isAccountConnected: false)
        let miner = makeMiner(campaigns: [campaign], priorityGames: ["Test Game"])

        let snapshot = resolveSnapshot(for: miner)

        XCTAssertNil(snapshot.upNext)
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

        XCTAssertEqual(idleSnapshot.statusText, "Up to Date")
        XCTAssertEqual(idleSnapshot.now.title, "Up to Date")
        XCTAssertNil(idleSnapshot.upNext)

        XCTAssertEqual(blockedSnapshot.statusText, "Blocked — Account not linked")
        XCTAssertEqual(blockedSnapshot.now.title, "Blocked — Account not linked")
        XCTAssertNil(blockedSnapshot.upNext)
    }

    func testDismissedMissingGameShowsCurrentStatusAsUpToDateAndAttemptableUpNext() {
        let campaign = makeCampaign(id: "unlinked", isAccountConnected: false)
        let miner = makeMiner(status: .blockedAccountNotLinked, campaigns: [campaign])

        let snapshot = MinerActivitySnapshot.resolve(
            for: miner,
            priorityGames: ["Test Game"],
            excludedGames: [],
            strategy: .prioritiseSelected,
            includesBadgeAndEmoteCampaigns: false,
            ignoredAccountLinkGameIds: ["game-1"]
        )

        XCTAssertEqual(snapshot.statusText, "Up to Date")
        XCTAssertEqual(snapshot.now.title, "Up to Date")
        XCTAssertEqual(snapshot.upNext?.campaignId, "unlinked")
        XCTAssertEqual(snapshot.upNext?.title, "Test Game")
        XCTAssertEqual(snapshot.upNext?.detail, "Likely based on current priority rules")
        XCTAssertFalse(snapshot.upNext?.requiresAccountLink ?? true)
        XCTAssertTrue(snapshot.blockedPriority.isEmpty)
    }

    func testClaimedPriorityGameWaitsForDropsInsteadOfSayingComplete() {
        let claimedProgress = Progress(
            dropId: "drop-1",
            campaignId: "claimed",
            currentMinutes: 60,
            requiredMinutes: 60,
            isClaimed: true
        )
        let claimedDrop = Drop(
            id: "drop-1",
            name: "Buoy",
            requiredMinutes: 60,
            progress: claimedProgress,
            isClaimed: true
        )
        let campaign = makeCampaign(
            id: "claimed",
            gameName: "ARC Raiders",
            isAccountConnected: true,
            drops: [claimedDrop]
        )
        let miner = makeMiner(
            campaigns: [campaign],
            priorityGames: ["ARC Raiders"]
        )

        let snapshot = MinerActivitySnapshot.resolve(
            for: miner,
            priorityGames: ["ARC Raiders"],
            excludedGames: [],
            strategy: .prioritiseSelected,
            includesBadgeAndEmoteCampaigns: false
        )

        XCTAssertEqual(snapshot.statusText, "Up to Date")
        XCTAssertEqual(snapshot.now.title, "Up to Date")
        XCTAssertEqual(snapshot.now.subtitle, "No active drops are available for this account.")
    }

    func testWatchingClaimedCurrentCampaignDoesNotShowAsMining() {
        let claimedProgress = Progress(
            dropId: "drop-1",
            campaignId: "claimed",
            currentMinutes: 60,
            requiredMinutes: 60,
            isClaimed: true
        )
        let claimedDrop = Drop(
            id: "drop-1",
            name: "Buoy",
            requiredMinutes: 60,
            progress: claimedProgress,
            isClaimed: true
        )
        let campaign = makeCampaign(
            id: "claimed",
            gameName: "ARC Raiders",
            isAccountConnected: true,
            drops: [claimedDrop]
        )
        let miner = makeMiner(
            status: .watching,
            campaigns: [campaign],
            currentCampaignId: "claimed",
            priorityGames: ["ARC Raiders"]
        )

        let snapshot = MinerActivitySnapshot.resolve(
            for: miner,
            priorityGames: ["ARC Raiders"],
            excludedGames: [],
            strategy: .prioritiseSelected,
            includesBadgeAndEmoteCampaigns: false
        )

        XCTAssertEqual(snapshot.statusText, "Up to Date")
        XCTAssertEqual(snapshot.now.title, "Up to Date")
        XCTAssertEqual(snapshot.now.subtitle, "No active drops are available for this account.")
        XCTAssertNotEqual(snapshot.now.campaignId, "claimed")
    }

    func testStalledMinerSurfacesOperationalStateInsteadOfNoCampaigns() {
        let miner = makeMiner(
            status: .idleNoEligibleCampaigns,
            campaigns: [],
            priorityGames: [],
            workerState: .running,
            isHealthy: false,
            isStalled: true
        )

        let snapshot = resolveSnapshot(for: miner)

        XCTAssertEqual(snapshot.statusText, "Miner Unresponsive")
        XCTAssertEqual(snapshot.now.title, "Miner Unresponsive")
    }

    func testRecoveringMinerSurfacesRecoveringState() {
        let miner = makeMiner(
            status: .idleNoEligibleCampaigns,
            campaigns: [],
            priorityGames: [],
            workerState: .recovering,
            isHealthy: false,
            isStalled: false
        )

        let snapshot = resolveSnapshot(for: miner)

        XCTAssertEqual(snapshot.statusText, "Recovering...")
        XCTAssertEqual(snapshot.now.title, "Recovering...")
    }
}
