import XCTest
@testable import SwiftMiner
@testable import SwiftMinerCore
import SwiftMinerService

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

    func testAccountLinkPendingItemBuildsTheDedicatedDiscordReminder() {
        let issue = PrioritisedLinkIssue(
            minerId: "miner-1",
            accountId: "account-1",
            minerName: "Test Miner",
            gameId: "halo",
            gameName: "Halo",
            campaignNames: ["Campaign Evolved"],
            isIgnored: false
        )
        let request = PendingItem(kind: .accountLink(issue), isMuted: false).dmRequest(
            miner: makeMiner(),
            priorityGames: ["Halo"]
        )

        XCTAssertEqual(request.messageType, .prioritisedGameNeedsLinking)
        XCTAssertEqual(request.affectedGame, "Halo")
        XCTAssertEqual(request.affectedGameId, "halo")
        XCTAssertEqual(request.campaignName, "Campaign Evolved")
        XCTAssertEqual(request.accountId, "account-1")
        XCTAssertEqual(request.priorityGames, ["Halo"])
    }

    func testSubscriptionPendingItemBuildsAnActionRequiredDM() {
        let item = PendingItem(
            kind: .subscriptionRequired(
                minerId: "miner-1",
                accountId: "account-1",
                campaignId: "campaign-1",
                gameName: "Diablo IV",
                campaignName: "Season Drops",
                dropNames: ["Helm", "Wings"]
            ),
            isMuted: false
        )
        let request = item.dmRequest(miner: makeMiner(), priorityGames: [])

        XCTAssertEqual(request.messageType, .accountActionRequired)
        XCTAssertEqual(request.affectedGame, "Diablo IV")
        XCTAssertEqual(request.campaignName, "Season Drops")
        XCTAssertTrue(request.recoveryReason?.contains("Helm, Wings") == true)
    }

    func testReauthenticationAttentionBuildsAReauthDM() throws {
        let miner = makeMiner(needsAuth: true)
        let attention = try XCTUnwrap(MinerAttentionIssue.resolve(miner: miner, events: []))
        let request = attention.dmRequest(miner: miner, priorityGames: ["Halo"])

        XCTAssertEqual(request.messageType, .reauth)
        XCTAssertEqual(request.twitchUsername, "tester")
        XCTAssertEqual(request.accountId, "account-1")
    }

    // MARK: - Dismissal

    /// The banner offers Dismiss only for the two reminders the user is allowed to silence.
    /// Everything else describes a miner that cannot earn until someone acts, so a Dismiss there
    /// would let the reason a miner is idle be hidden — which is what the banner exists to prevent.
    func testOnlyTheCampaignRemindersCanBeDismissed() {
        var miner = makeMiner()
        miner.debugAttention = .accountLink(gameName: "Halo")
        XCTAssertEqual(
            MinerAttentionIssue.resolve(miner: miner, events: [])?.dismissal,
            .accountLink(gameId: "debug-fake-link-game", gameName: "Halo")
        )

        miner.debugAttention = .subscriptionRequired
        XCTAssertEqual(
            MinerAttentionIssue.resolve(miner: miner, events: [])?.dismissal,
            .subscriptionRequired(campaignId: "debug-fake-campaign")
        )
    }

    func testBlockingStatesOfferNoDismissal() {
        let reAuth = MinerAttentionIssue.resolve(miner: makeMiner(needsAuth: true), events: [])
        XCTAssertEqual(reAuth?.title, "Twitch needs to be reconnected")
        XCTAssertNil(reAuth?.dismissal, "Re-authentication is not something the user may silence.")

        let stopped = MinerAttentionIssue.resolve(
            miner: makeMiner(status: .error, workerState: .failed),
            events: []
        )
        XCTAssertEqual(stopped?.title, "The mining worker stopped")
        XCTAssertNil(stopped?.dismissal)

        let blocked = MinerAttentionIssue.resolve(miner: makeMiner(status: .blockedAccountNotLinked), events: [])
        XCTAssertEqual(blocked?.title, "Link a game account to Twitch")
        XCTAssertNil(
            blocked?.dismissal,
            "This fallback has no campaign behind it, so there is no per-game mute to write."
        )
    }

    // MARK: - Approved-channel liveness checks

    /// A miner that keeps watching while the liveness query is broken shows nothing today.
    /// It is the campaigns limited to specific channels — esports windows — that go missing,
    /// so a run of failed checks has to reach the user while the miner still looks fine.
    func testRepeatedApprovedChannelProbeFailuresRaiseAttentionOnARunningMiner() {
        let miner = makeMiner()
        let events = (0..<3).map { index in
            EventEntry(
                message: "[ChannelSelect]   Approved-channel liveness batch failed: 3/3 checks failed (\(index + 1) consecutive batch(es))",
                level: .warning,
                minerId: miner.id
            )
        }

        let attention = MinerAttentionIssue.resolve(miner: miner, events: events)

        XCTAssertEqual(attention?.title, "Restricted campaigns can't be checked")
        XCTAssertEqual(attention?.action, .restart)
        XCTAssertEqual(attention?.detail, "SwiftMiner could not check restricted channels — 3 scan batches failed in the last 30 minutes.")
    }

    /// One failed probe is routine — a rescan cancels in-flight checks all the time.
    func testASingleApprovedChannelProbeFailureIsNotWorthInterrupting() {
        let miner = makeMiner()
        let event = EventEntry(
            message: "[ChannelSelect]   Approved-channel liveness batch failed: 1/1 checks failed (1 consecutive batch(es))",
            level: .warning,
            minerId: miner.id
        )

        XCTAssertNil(MinerAttentionIssue.resolve(miner: miner, events: [event]))
    }

    func testApprovedChannelProbeFailuresOutsideTheWindowAreIgnored() {
        let miner = makeMiner()
        let stale = Date().addingTimeInterval(-(MinerAttention.approvedChannelProbeFailureWindow + 60))
        let events = (0..<5).map { index in
            EventEntry(
                timestamp: stale,
                message: "[ChannelSelect]   Approved-channel liveness batch failed: 3/3 checks failed (\(index + 1) consecutive batch(es))",
                level: .warning,
                minerId: miner.id
            )
        }

        XCTAssertNil(MinerAttentionIssue.resolve(miner: miner, events: events))
    }

    /// Another miner's failures are not this miner's problem.
    func testApprovedChannelProbeFailuresFromAnotherMinerAreIgnored() {
        let miner = makeMiner()
        let events = (0..<4).map { index in
            EventEntry(
                message: "[ChannelSelect]   Approved-channel liveness batch failed: 3/3 checks failed (\(index + 1) consecutive batch(es))",
                level: .warning,
                minerId: "someone-else"
            )
        }

        XCTAssertNil(MinerAttentionIssue.resolve(miner: miner, events: events))
    }

    /// A stopped worker has its own, more urgent story; this must not displace it.
    func testAFailedWorkerStillReportsItsOwnFailureFirst() {
        let miner = makeMiner(status: .error, workerState: .failed)
        var events = (0..<4).map { index in
            EventEntry(
                message: "[ChannelSelect]   Approved-channel liveness batch failed: 3/3 checks failed (\(index + 1) consecutive batch(es))",
                level: .warning,
                minerId: miner.id
            )
        }
        events.append(EventEntry(message: "Error: worker stopped", level: .error, minerId: miner.id))

        XCTAssertEqual(MinerAttentionIssue.resolve(miner: miner, events: events)?.title, "The mining worker stopped")
    }

    func testSuccessfulBatchBreaksTheLogDerivedFailureRun() {
        let miner = makeMiner()
        let now = Date()
        var events = (0..<3).map { index in
            EventEntry(
                timestamp: now.addingTimeInterval(TimeInterval(index)),
                message: "[ChannelSelect]   Approved-channel liveness batch failed: 3/3 checks failed",
                level: .warning,
                minerId: miner.id
            )
        }
        events.append(EventEntry(
            timestamp: now.addingTimeInterval(3),
            message: "[ChannelSelect]   Approved-channel liveness checks are working again",
            level: .info,
            minerId: miner.id
        ))
        events.append(contentsOf: (4..<6).map { index in
            EventEntry(
                timestamp: now.addingTimeInterval(TimeInterval(index)),
                message: "[ChannelSelect]   Approved-channel liveness batch failed: 3/3 checks failed",
                level: .warning,
                minerId: miner.id
            )
        })

        XCTAssertNil(MinerAttentionIssue.resolve(miner: miner, events: events))
    }

    func testCompatibilityFailuresAreTheOnlyOnesTreatedAsPermanent() {
        let compatibility = TwitchMinerError.twitchAPICompatibility(
            operation: "VideoPlayerStreamInfoOverlayChannel",
            reason: "The response no longer contains the stream."
        )
        let network = TwitchMinerError.networkError("The request timed out")

        XCTAssertTrue(MinerEngine.isCompatibilityFailure(compatibility))
        XCTAssertFalse(MinerEngine.isCompatibilityFailure(network))
        XCTAssertFalse(MinerEngine.isCompatibilityFailure(CancellationError()))
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
