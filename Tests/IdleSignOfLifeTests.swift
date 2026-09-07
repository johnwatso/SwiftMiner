import XCTest
@testable import SwiftMiner
@testable import SwiftMinerCore

/// Two failure modes that both looked like "the miner is stuck": a setting that was on and
/// doing nothing without saying so, and an idle row that published nothing for minutes.
@MainActor
final class IdleSignOfLifeTests: XCTestCase {

    // MARK: Follow-lookup availability

    /// `prioritiseFollowedStreamers` going inert used to be reported only to `Logger.api`,
    /// which never reaches the Activity Log — so the toggle stayed on while ranking ignored
    /// follow state, with nothing on screen to say why.
    func testInertFollowLookupIsWordedAsAWarningTheUserWillSee() {
        let notices: [TwitchAPIClient.FollowLookupNotice] = [
            .unavailableForSession(reason: "401 Unauthorized"),
            .backingOff(minutes: 5, reason: "The request timed out.")
        ]

        for notice in notices {
            let message = notice.logMessage
            XCTAssertTrue(
                message.hasPrefix("Warning: "),
                "an inert setting must log at warning level, not slip by as info: \(message)"
            )
            XCTAssertTrue(
                message.lowercased().contains("followed-streamer prioritisation"),
                "the message must name the setting that is not working: \(message)"
            )
            XCTAssertEqual(
                primaryEventFilter(for: EventEntry(message: message, level: .warning)),
                .warnings,
                "the notice must file under Warnings so it survives retention: \(message)"
            )
        }
    }

    func testRecoveredFollowLookupIsNotAWarning() {
        let message = TwitchAPIClient.FollowLookupNotice.recovered.logMessage
        XCTAssertFalse(message.hasPrefix("Warning: "))
        XCTAssertTrue(message.lowercased().contains("working again"))
    }

    // MARK: Idle next-check

    func testIdleMinerCarriesTheTimeItWillNextLookForWork() {
        let deadline = Date(timeIntervalSince1970: 10_300)
        var miner = MinerManager.ManagedMiner(
            id: "miner",
            accountId: "account",
            username: "tester",
            status: .idleNoEligibleCampaigns,
            isRunning: true,
            priorityGames: []
        )
        XCTAssertNil(miner.nextCampaignCheckAt, "a miner that is not waiting must not show a countdown")

        miner.nextCampaignCheckAt = deadline
        XCTAssertEqual(miner.nextCampaignCheckAt, deadline)

        // The engine clears it as a cycle starts. A value left behind would render as a
        // countdown that never moves, which is the frozen row wearing a clock.
        miner.nextCampaignCheckAt = nil
        XCTAssertNil(miner.nextCampaignCheckAt)
    }

    /// The countdown is published from the engine's own deadline rather than assumed to be
    /// five minutes. Today the cap equals the base, so repeated empty scans do not stretch the
    /// wait — a deliberate call that newly-started short campaigns must not wait to be found.
    /// If that cap is ever raised, the UI follows without another change.
    func testNoCandidateWaitStaysWithinItsConfiguredBounds() {
        for cycles in 1...10 {
            let interval = MinerEngine.noCandidateBackoffInterval(for: cycles)
            XCTAssertGreaterThanOrEqual(interval, MinerEngine.noCandidateBackoffBaseInterval)
            XCTAssertLessThanOrEqual(interval, MinerEngine.noCandidateBackoffMaxInterval)
        }
    }
}
