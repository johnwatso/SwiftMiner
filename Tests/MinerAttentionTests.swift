import XCTest
@testable import SwiftMiner
@testable import SwiftMinerCore

@MainActor
final class MinerAttentionTests: XCTestCase {
    func testFailedWorkerShowsLatestErrorAndRestartAction() {
        let miner = makeMiner(status: .error, workerState: .failed)
        let error = EventEntry(
            message: "Error: Watch session failed: Session already active",
            level: .error,
            minerId: miner.id
        )

        let attention = MinerAttentionIssue.resolve(miner: miner, events: [error])

        XCTAssertEqual(attention?.title, "The mining worker stopped")
        XCTAssertEqual(attention?.detail, error.message)
        XCTAssertEqual(attention?.action, .restart)
    }

    func testAuthenticationRequirementTakesPriorityOverGenericWorkerFailure() {
        let miner = makeMiner(status: .error, needsAuth: true, workerState: .failed)

        let attention = MinerAttentionIssue.resolve(miner: miner, events: [])

        XCTAssertEqual(attention?.title, "Twitch needs to be reconnected")
        XCTAssertEqual(attention?.action, .reconnect)
    }

    func testBlockedAccountLinkShowsTwitchDropsAction() {
        let miner = makeMiner(status: .blockedAccountNotLinked)

        let attention = MinerAttentionIssue.resolve(miner: miner, events: [])

        XCTAssertEqual(attention?.title, "Link a game account to Twitch")
        XCTAssertEqual(attention?.action, .openTwitchDrops)
        XCTAssertTrue(attention?.recommendation.contains("Open Twitch Drops") == true)
    }

#if DEBUG
    func testDebugAccountLinkPreviewShowsTheSameActionableWarning() {
        var miner = makeMiner()
        miner.debugAttention = .accountLink(gameName: "Halo")

        let attention = MinerAttentionIssue.resolve(miner: miner, events: [])

        XCTAssertEqual(attention?.title, "Link Halo to Twitch")
        XCTAssertEqual(attention?.action, .openTwitchDrops)
    }
#endif

    func testCompatibilityFailureExplainsThatSwiftMinerNeedsAnUpdate() {
        let miner = makeMiner(status: .error, workerState: .failed)
        let error = EventEntry(
            message: "Error: Twitch compatibility update required for Inventory. Update SwiftMiner, then try again.",
            level: .error,
            minerId: miner.id
        )

        let attention = MinerAttentionIssue.resolve(miner: miner, events: [error])

        XCTAssertEqual(attention?.title, "SwiftMiner needs a Twitch update")
        XCTAssertEqual(attention?.action, .restart)
    }

    func testHealthyMinerHasNoAttentionPanel() {
        XCTAssertNil(MinerAttentionIssue.resolve(miner: makeMiner(), events: []))
    }

    func testNotEarningMinerExplainsMissingProgress() {
        var miner = makeMiner()
        miner.lastDropProgressAt = Date().addingTimeInterval(-25 * 60)
        miner.workerStartedAt = Date().addingTimeInterval(-2 * 60 * 60)

        let attention = MinerAttentionIssue.resolve(miner: miner, events: [])

        XCTAssertEqual(attention?.title, "This miner is not earning drop progress")
        XCTAssertEqual(attention?.action, .restart)
        XCTAssertTrue(attention?.detail.contains("25 minutes") == true)
    }

    func testAccountLinkReminderExplainsHowToResolveIt() {
        let issue = PrioritisedLinkIssue(
            minerId: "miner-1",
            accountId: "account-1",
            minerName: "tester",
            gameId: "halo",
            gameName: "Halo",
            campaignNames: ["Campaign Evolved"],
            isIgnored: false
        )
        let item = PendingItem(kind: .accountLink(issue), isMuted: false)

        XCTAssertEqual(item.title, "Link Halo to Twitch")
        XCTAssertEqual(item.resolutionTitle, "Open Twitch Drops")
        XCTAssertTrue(item.subtitle.contains("open Twitch Drops"))
        XCTAssertTrue(item.subtitle.contains("link your game account"))
    }

    func testMutedAccountLinkReminderStillOffersTheResolution() {
        let issue = PrioritisedLinkIssue(
            minerId: "miner-1",
            accountId: "account-1",
            minerName: "tester",
            gameId: "overwatch",
            gameName: "Overwatch",
            campaignNames: ["Overwatch Drops"],
            isIgnored: true
        )
        let item = PendingItem(kind: .accountLink(issue), isMuted: true)

        XCTAssertEqual(item.resolutionTitle, "Open Twitch Drops")
        XCTAssertEqual(item.actionTitle, "Remind me")
        XCTAssertTrue(item.subtitle.contains("Reminder muted"))
    }

    private func makeMiner(
        status: MinerManager.MinerStatus = .watching,
        needsAuth: Bool = false,
        workerState: MinerWorkerState = .running
    ) -> MinerManager.ManagedMiner {
        MinerManager.ManagedMiner(
            id: "miner-1",
            accountId: "account-1",
            username: "tester",
            status: status,
            needsAuth: needsAuth,
            isRunning: true,
            workerState: workerState,
            isHealthy: workerState != .failed
        )
    }
}
