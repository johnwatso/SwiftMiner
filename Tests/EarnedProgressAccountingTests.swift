import XCTest
@testable import SwiftMinerCore

/// Earning has to be measured per drop. These cover the cases where aggregate totals lie:
/// a claim empties in-flight progress, and campaigns carry existing progress in and out of
/// the account's active set.
final class EarnedProgressAccountingTests: XCTestCase {
    private var tracker = DropProgressEventTracker()

    override func setUp() {
        super.setUp()
        tracker = DropProgressEventTracker()
    }

    private func observe(
        drop: String,
        campaign: String? = "campaign",
        minutes: Int,
        required: Int? = 60
    ) -> DropProgressUpdateResult {
        tracker.observe(
            DropProgressObservation(
                campaignId: campaign,
                dropId: drop,
                dropLabel: drop,
                currentMinutes: minutes,
                requiredMinutes: required,
                source: .gqlPoll
            )
        )
    }

    func testFirstObservationCreditsOnlyWhatWasEarned() {
        XCTAssertEqual(observe(drop: "a", minutes: 5).earnedMinutes, 5)
    }

    func testSuccessiveObservationsCreditOnlyTheDelta() {
        XCTAssertEqual(observe(drop: "a", minutes: 5).earnedMinutes, 5)
        XCTAssertEqual(observe(drop: "a", minutes: 12).earnedMinutes, 7)
        XCTAssertEqual(observe(drop: "a", minutes: 12).earnedMinutes, 0)
    }

    /// A drop crossing its requirement reports `.claimable`, not `.progress`. Counting only
    /// `.progress` would silently drop the closing minutes of every drop that completes.
    func testCrossingTheRequirementStillCreditsItsMinutes() {
        XCTAssertEqual(observe(drop: "a", minutes: 55).earnedMinutes, 55)

        let completing = observe(drop: "a", minutes: 60)
        if case .claimable = completing.transition {} else {
            XCTFail("expected a claimable transition, got \(completing.transition)")
        }
        XCTAssertEqual(completing.earnedMinutes, 5)
    }

    /// Twitch re-reporting a lower value must never register as negative earning, and must
    /// not let the same minutes be credited twice when the value recovers.
    func testRegressionCreditsNothingAndDoesNotDoubleCount() {
        XCTAssertEqual(observe(drop: "a", minutes: 30).earnedMinutes, 30)
        XCTAssertEqual(observe(drop: "a", minutes: 10).earnedMinutes, 0)
        XCTAssertEqual(observe(drop: "a", minutes: 30).earnedMinutes, 0)
        XCTAssertEqual(observe(drop: "a", minutes: 34).earnedMinutes, 4)
    }

    func testClaimingCreditsNoMinutes() {
        XCTAssertEqual(observe(drop: "a", minutes: 40).earnedMinutes, 40)
        XCTAssertEqual(
            tracker.markClaimed(campaignId: "campaign", dropId: "a", dropLabel: "a").earnedMinutes,
            0
        )
    }

    /// The failure that made the shipped ledger unusable: a claim empties in-flight progress
    /// and a campaign rejoining the set restores it, so the account-wide total falls and
    /// rises for reasons that have nothing to do with earning. Per-drop accounting has to be
    /// immune to both.
    func testEarningIsUnaffectedByTotalsMovingForOtherReasons() {
        // Two drops accrue independently.
        XCTAssertEqual(observe(drop: "a", campaign: "one", minutes: 60, required: 60).earnedMinutes, 60)
        XCTAssertEqual(observe(drop: "b", campaign: "two", minutes: 10).earnedMinutes, 10)

        // Claiming the finished drop removes 60 minutes from any aggregate total.
        _ = tracker.markClaimed(campaignId: "one", dropId: "a", dropLabel: "a")

        // The other drop keeps earning, and its delta is credited in full despite the
        // account-wide total having just dropped by more than it gained.
        XCTAssertEqual(observe(drop: "b", campaign: "two", minutes: 13).earnedMinutes, 3)

        // A campaign rejoining the set re-reports progress already counted; credit nothing.
        XCTAssertEqual(observe(drop: "b", campaign: "two", minutes: 13).earnedMinutes, 0)
    }

    func testProgressOnAClaimedDropIsNotRecounted() {
        XCTAssertEqual(observe(drop: "a", minutes: 60, required: 60).earnedMinutes, 60)
        _ = tracker.markClaimed(campaignId: "campaign", dropId: "a", dropLabel: "a")
        XCTAssertEqual(observe(drop: "a", minutes: 60, required: 60).earnedMinutes, 0)
    }
}
