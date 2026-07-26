import XCTest
@testable import SwiftMinerCore
@testable import SwiftMiner
import SwiftMinerService

@MainActor
final class MinerActivitySnapshotTests: XCTestCase {

    func testGlobalPriorityToggleOnlyAppearsForMultipleMiners() {
        XCTAssertFalse(MinersOverviewView.shouldShowGlobalPriorityToggle(minerCount: 0))
        XCTAssertFalse(MinersOverviewView.shouldShowGlobalPriorityToggle(minerCount: 1))
        XCTAssertTrue(MinersOverviewView.shouldShowGlobalPriorityToggle(minerCount: 2))
    }

    private func makeMiner(
        status: MinerManager.MinerStatus = .idle,
        campaigns: [Campaign],
        currentCampaignId: String? = nil,
        priorityGames: [String] = ["Test Game"],
        workerState: MinerWorkerState = .running,
        isRunning: Bool = true,
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
            isRunning: isRunning,
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

    func testStoppedMinerIsNeverPresentedAsUpToDate() {
        let miner = makeMiner(
            status: .idleNoEligibleCampaigns,
            campaigns: [],
            priorityGames: [],
            workerState: .idle,
            isRunning: false
        )

        let snapshot = resolveSnapshot(for: miner)

        XCTAssertEqual(miner.statusLabel, "Stopped")
        XCTAssertEqual(snapshot.statusText, "Stopped")
        XCTAssertEqual(snapshot.now.title, "Stopped")
        XCTAssertEqual(snapshot.now.subtitle, "Start this miner to check for and earn drops.")
    }

    func testPendingMinerStartupIsPresentedAsStarting() {
        let miner = makeMiner(
            status: .authenticating,
            campaigns: [],
            priorityGames: [],
            workerState: .idle,
            isRunning: false
        )

        let snapshot = resolveSnapshot(for: miner)

        XCTAssertEqual(miner.statusLabel, "Starting...")
        XCTAssertEqual(snapshot.statusText, "Starting...")
        XCTAssertEqual(snapshot.now.title, "Starting...")
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

    func testWaitingForStreamSurfacesSubscriptionRequiredPriorityCampaign() {
        let creators = makeCampaign(
            id: "creators",
            gameId: "g007",
            gameName: "007 First Light",
            isAccountConnected: false,
            drops: [Drop(id: "creator-drop", name: "Creator Drop", requiredMinutes: 60)]
        )
        let launchBadge = makeCampaign(
            id: "launch-sub",
            gameId: "g007",
            gameName: "007 First Light",
            isAccountConnected: false,
            drops: [
                Drop(
                    id: "badge",
                    name: "007 Gun Barrel Badge",
                    requiredMinutes: 0,
                    requiredSubs: 1
                )
            ]
        )
        let miner = makeMiner(
            status: .waitingForStream,
            campaigns: [creators, launchBadge],
            priorityGames: ["007 First Light"]
        )

        let snapshot = MinerActivitySnapshot.resolve(
            for: miner,
            priorityGames: ["007 First Light"],
            excludedGames: [],
            strategy: .prioritiseSelected,
            includesBadgeAndEmoteCampaigns: false
        )

        XCTAssertEqual(snapshot.statusText, "Subscription Required")
        XCTAssertEqual(snapshot.now.title, "Subscription Required")
        XCTAssertEqual(snapshot.now.subtitle, "007 First Light")
        XCTAssertEqual(snapshot.now.detail, "007 Gun Barrel Badge needs a paid Twitch sub.")
    }

    func testSubscriptionRequiredCurrentStateSuppressesSameGameUpNext() {
        let creators = makeCampaign(
            id: "creators",
            gameId: "g007",
            gameName: "007 First Light",
            isAccountConnected: false,
            drops: [Drop(id: "creator-drop", name: "Creator Drop", requiredMinutes: 60)]
        )
        let launchBadge = makeCampaign(
            id: "launch-sub",
            gameId: "g007",
            gameName: "007 First Light",
            isAccountConnected: false,
            drops: [
                Drop(
                    id: "badge",
                    name: "007 Gun Barrel Badge",
                    requiredMinutes: 0,
                    requiredSubs: 1
                )
            ]
        )
        let miner = makeMiner(
            status: .waitingForStream,
            campaigns: [creators, launchBadge],
            priorityGames: ["007 First Light"]
        )

        let snapshot = MinerActivitySnapshot.resolve(
            for: miner,
            priorityGames: ["007 First Light"],
            excludedGames: [],
            strategy: .prioritiseSelected,
            includesBadgeAndEmoteCampaigns: false
        )

        XCTAssertEqual(snapshot.statusText, "Subscription Required")
        XCTAssertNil(snapshot.upNext)
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

    func testUnhealthyRefreshAndBlockedStatesDoNotCollapseToNoRecentActivity() {
        let refreshingMiner = makeMiner(
            status: .fetchingCampaigns,
            campaigns: [],
            priorityGames: [],
            workerState: .running,
            isHealthy: false
        )
        let errorMiner = makeMiner(
            status: .error,
            campaigns: [],
            priorityGames: [],
            workerState: .running,
            isHealthy: false
        )
        let idleMiner = makeMiner(
            status: .idleNoEligibleCampaigns,
            campaigns: [],
            priorityGames: [],
            workerState: .running,
            isHealthy: false
        )

        let refreshingSnapshot = resolveSnapshot(for: refreshingMiner)
        let errorSnapshot = resolveSnapshot(for: errorMiner)
        let idleSnapshot = resolveSnapshot(for: idleMiner)

        XCTAssertEqual(refreshingSnapshot.statusText, "Up to Date")
        XCTAssertEqual(refreshingSnapshot.now.title, "Up to Date")

        XCTAssertEqual(errorSnapshot.statusText, "Blocked — Needs attention")
        XCTAssertEqual(errorSnapshot.now.title, "Blocked — Needs attention")

        XCTAssertEqual(idleSnapshot.statusText, "Up to Date")
        XCTAssertEqual(idleSnapshot.now.title, "Up to Date")
    }

    func testUnhealthyWatchingMinerStillSurfacesNoRecentActivity() {
        let miner = makeMiner(
            status: .watching,
            campaigns: [],
            priorityGames: [],
            workerState: .running,
            isHealthy: false
        )

        let snapshot = resolveSnapshot(for: miner)

        XCTAssertEqual(snapshot.statusText, "No Recent Activity")
        XCTAssertEqual(snapshot.now.title, "No Recent Activity")
    }

    func testWebCampaignSummaryMarksSubscriptionOnlyCampaignAsGated() {
        let now = Date()
        let campaign = Campaign(
            id: "subscription-only",
            name: "Subscription Campaign",
            game: Game(id: "game", name: "Test Game"),
            status: .active,
            startDate: now.addingTimeInterval(-60),
            endDate: now.addingTimeInterval(3_600),
            drops: [
                Drop(id: "sub-drop", name: "Subscriber Reward", requiredMinutes: 0, requiredSubs: 1)
            ],
            isAccountConnected: true
        )

        let summary = NavigationModel.webCampaignSummary(from: campaign)

        XCTAssertTrue(summary.requiresSubscription)
        XCTAssertEqual(summary.subscriptionRequiredDropCount, 1)
    }
}
