import XCTest
@testable import SwiftMinerCore

/// Earning has to be measured per drop. These cover the cases where aggregate totals lie:
/// a claim empties in-flight progress, and campaigns carry existing progress in and out of
/// the account's active set. They also cover the plausibility bound, which exists so
/// telemetry that cannot be true says so instead of quietly landing in the ledger.
final class EarnedProgressAccountingTests: XCTestCase {
    private var tracker = DropProgressEventTracker()
    private var clock = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() {
        super.setUp()
        tracker = DropProgressEventTracker()
        clock = Date(timeIntervalSince1970: 1_700_000_000)
    }

    /// `gap` is the wall-clock time since the previous observation. It defaults to an hour
    /// so tests about delta arithmetic are not also testing the plausibility bound; tests
    /// that care about the bound pass it explicitly.
    @discardableResult
    private func observe(
        drop: String,
        campaign: String? = "campaign",
        minutes: Int,
        required: Int? = 60,
        after gap: TimeInterval = 3600
    ) -> DropProgressUpdateResult {
        clock = clock.addingTimeInterval(gap)
        return tracker.observe(
            DropProgressObservation(
                campaignId: campaign,
                dropId: drop,
                dropLabel: drop,
                currentMinutes: minutes,
                requiredMinutes: required,
                source: .gqlPoll,
                observedAt: clock
            )
        )
    }

    // MARK: - Per-drop accounting

    /// A drop's first sighting reports whatever it already had banked, which may have been
    /// earned days ago or on another device. Counting it credited a campaign's entire
    /// history the moment a miner switched to it — one account booked 540 minutes in a
    /// single hour that way.
    func testFirstObservationEstablishesABaselineAndEarnsNothing() {
        XCTAssertEqual(observe(drop: "a", minutes: 47).earnedMinutes, 0)
    }

    func testSuccessiveObservationsCreditOnlyTheDelta() {
        XCTAssertEqual(observe(drop: "a", minutes: 5).earnedMinutes, 0)
        XCTAssertEqual(observe(drop: "a", minutes: 12).earnedMinutes, 7)
        XCTAssertEqual(observe(drop: "a", minutes: 12).earnedMinutes, 0)
    }

    /// Switching to a campaign with hours of existing progress must credit nothing for it,
    /// then track its real movement from there.
    func testSwitchingToACampaignWithExistingProgressCreditsNothing() {
        XCTAssertEqual(observe(drop: "x", campaign: "other", minutes: 58).earnedMinutes, 0)
        XCTAssertEqual(observe(drop: "y", campaign: "other", minutes: 51).earnedMinutes, 0)
        XCTAssertEqual(observe(drop: "x", campaign: "other", minutes: 60).earnedMinutes, 2)
    }

    /// A drop crossing its requirement reports `.claimable`, not `.progress`. Counting only
    /// `.progress` would silently drop the closing minutes of every drop that completes.
    func testCrossingTheRequirementStillCreditsItsMinutes() {
        XCTAssertEqual(observe(drop: "a", minutes: 50).earnedMinutes, 0)

        let completing = observe(drop: "a", minutes: 60)
        if case .claimable = completing.transition {} else {
            XCTFail("expected a claimable transition, got \(completing.transition)")
        }
        XCTAssertEqual(completing.earnedMinutes, 10)
    }

    /// Twitch re-reporting a lower value must never register as negative earning, and must
    /// not let the same minutes be credited twice when the value recovers.
    func testRegressionCreditsNothingAndDoesNotDoubleCount() {
        XCTAssertEqual(observe(drop: "a", minutes: 30).earnedMinutes, 0)
        XCTAssertEqual(observe(drop: "a", minutes: 10).earnedMinutes, 0)
        XCTAssertEqual(observe(drop: "a", minutes: 30).earnedMinutes, 0)
        XCTAssertEqual(observe(drop: "a", minutes: 34).earnedMinutes, 4)
    }

    func testClaimingCreditsNoMinutes() {
        XCTAssertEqual(observe(drop: "a", minutes: 40).earnedMinutes, 0)
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
        XCTAssertEqual(observe(drop: "a", campaign: "one", minutes: 55, required: 60).earnedMinutes, 0)
        XCTAssertEqual(observe(drop: "a", campaign: "one", minutes: 60, required: 60).earnedMinutes, 5)
        XCTAssertEqual(observe(drop: "b", campaign: "two", minutes: 10).earnedMinutes, 0)

        // Claiming the finished drop removes 60 minutes from any aggregate total.
        _ = tracker.markClaimed(campaignId: "one", dropId: "a", dropLabel: "a")

        // The other drop keeps earning, and its delta is credited in full despite the
        // account-wide total having just fallen by more than it gained.
        XCTAssertEqual(observe(drop: "b", campaign: "two", minutes: 13).earnedMinutes, 3)

        // A campaign rejoining the set re-reports progress already counted; credit nothing.
        XCTAssertEqual(observe(drop: "b", campaign: "two", minutes: 13).earnedMinutes, 0)
    }

    func testProgressOnAClaimedDropIsNotRecounted() {
        XCTAssertEqual(observe(drop: "a", minutes: 55, required: 60).earnedMinutes, 0)
        XCTAssertEqual(observe(drop: "a", minutes: 60, required: 60).earnedMinutes, 5)
        _ = tracker.markClaimed(campaignId: "campaign", dropId: "a", dropLabel: "a")
        XCTAssertEqual(observe(drop: "a", minutes: 60, required: 60).earnedMinutes, 0)
    }

    // MARK: - Plausibility bound

    /// A drop accrues at most a minute per minute. Anything beyond the elapsed wall clock
    /// was not earned here — it may be another device's watching, or a defect in our own
    /// accounting — and neither belongs in this miner's ledger.
    func testEarningIsBoundedByElapsedWallClock() {
        observe(drop: "a", minutes: 10)

        // Twenty minutes claimed one minute after the previous sighting.
        let jump = observe(drop: "a", minutes: 30, after: 60)
        let bound = 1 + DropProgressUpdateResult.plausibilitySlackMinutes

        XCTAssertEqual(jump.reportedEarnedMinutes, 20)
        XCTAssertEqual(jump.earnedMinutes, bound)
        XCTAssertEqual(jump.implausibleMinutesDiscarded, 20 - bound)
    }

    /// Progress that keeps pace with the clock is credited in full and never flagged.
    func testNormalProgressIsNeverDiscarded() {
        observe(drop: "a", minutes: 10)

        for minute in 11...20 {
            let result = observe(drop: "a", minutes: minute, after: 60)
            XCTAssertEqual(result.earnedMinutes, 1)
            XCTAssertEqual(result.implausibleMinutesDiscarded, 0)
        }
    }

    /// A long, legitimate gap allows a correspondingly larger credit.
    func testLongGapAllowsProportionallyMoreProgress() {
        observe(drop: "a", minutes: 10)

        let result = observe(drop: "a", minutes: 40, after: 30 * 60)

        XCTAssertEqual(result.reportedEarnedMinutes, 30)
        XCTAssertEqual(result.earnedMinutes, 30)
        XCTAssertEqual(result.implausibleMinutesDiscarded, 0)
    }

    /// Polling more often than Twitch credits progress must not shorten the plausibility
    /// window. The five-minute gain is honest even though the final poll is only one minute
    /// after an unchanged sample.
    func testUnchangedPollDoesNotResetProgressBaseline() {
        observe(drop: "a", minutes: 10)
        observe(drop: "a", minutes: 10, after: 4 * 60)

        let batch = observe(drop: "a", minutes: 15, after: 60)

        XCTAssertEqual(batch.secondsSinceProgressBaseline, 5 * 60)
        XCTAssertEqual(batch.earnedMinutes, 5)
        XCTAssertEqual(batch.implausibleMinutesDiscarded, 0)
    }

    /// A stale source can briefly report less progress than the accepted maximum. That
    /// sample must not erase elapsed time before the authoritative source catches up.
    func testRegressionDoesNotResetProgressBaseline() {
        observe(drop: "a", minutes: 10)
        observe(drop: "a", minutes: 8, after: 4 * 60)

        let recovered = observe(drop: "a", minutes: 15, after: 60)

        XCTAssertEqual(recovered.secondsSinceProgressBaseline, 5 * 60)
        XCTAssertEqual(recovered.earnedMinutes, 5)
        XCTAssertEqual(recovered.implausibleMinutesDiscarded, 0)
    }

    /// The exact shape of the 1.34.4 defect: switching to a campaign carrying hours of
    /// existing progress. The baseline rule credits nothing and the bound independently
    /// agrees — either alone would have caught it.
    func testCampaignSwitchBaselineIsBothZeroAndOutOfBounds() {
        let first = observe(drop: "x", campaign: "other", minutes: 540)

        XCTAssertEqual(first.earnedMinutes, 0)
        XCTAssertEqual(first.reportedEarnedMinutes, 0)
        XCTAssertEqual(first.plausibleEarnedMinutesBound, 0)
    }

    func testMonotonicProgressClockSurvivesWallClockMovingBackwards() {
        var localTracker = DropProgressEventTracker()
        _ = localTracker.observe(DropProgressObservation(
            campaignId: "campaign",
            dropId: "drop",
            dropLabel: "Drop",
            currentMinutes: 10,
            requiredMinutes: 60,
            source: .gqlPoll,
            observedAt: Date(timeIntervalSince1970: 1_000),
            observedUptimeNanoseconds: 1_000_000_000
        ))

        let result = localTracker.observe(DropProgressObservation(
            campaignId: "campaign",
            dropId: "drop",
            dropLabel: "Drop",
            currentMinutes: 13,
            requiredMinutes: 60,
            source: .gqlPoll,
            observedAt: Date(timeIntervalSince1970: 900), // user/NTP moved the wall clock back
            observedUptimeNanoseconds: 181_000_000_000
        ))

        XCTAssertEqual(result.secondsSinceProgressBaseline, 180)
        XCTAssertEqual(result.earnedMinutes, 3)
        XCTAssertEqual(result.implausibleMinutesDiscarded, 0)
    }
}
