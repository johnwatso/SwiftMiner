import XCTest
@testable import SwiftMinerCore

/// Covers the drop-aware scheduling helpers: preferring nearly-complete drops
/// and deferring preemption so banked (per-campaign) watch time isn't stranded.
final class MinerSchedulingTests: XCTestCase {

    private let now = Date()
    private let game = Game(id: "g1", name: "Test Game")

    private func drop(
        id: String,
        required: Int,
        current: Int? = nil,
        claimed: Bool = false
    ) -> Drop {
        let progress = current.map {
            Progress(
                id: "p-\(id)", dropId: id, dropName: id,
                campaignId: "c", currentMinutes: $0, requiredMinutes: required
            )
        }
        return Drop(id: id, name: id, requiredMinutes: required, progress: progress, isClaimed: claimed)
    }

    private func campaign(id: String, endsInDays days: Double, drops: [Drop]) -> Campaign {
        Campaign(
            id: id, name: id, game: game, status: .active,
            startDate: now.addingTimeInterval(-3600),
            endDate: now.addingTimeInterval(days * 86_400),
            drops: drops,
            isAccountConnected: true
        )
    }

    // MARK: - minutesToNearestClaim

    func testMinutesToNearestClaim_NoProgress_IsMax() {
        let c = campaign(id: "c", endsInDays: 5, drops: [drop(id: "d1", required: 60)])
        XCTAssertEqual(MinerEngine.minutesToNearestClaim(c), Int.max)
    }

    func testMinutesToNearestClaim_UsesMostAdvancedUnclaimedDrop() {
        let c = campaign(id: "c", endsInDays: 5, drops: [
            drop(id: "d1", required: 60, current: 20),   // 40 remaining
            drop(id: "d2", required: 120, current: 115), // 5 remaining
        ])
        XCTAssertEqual(MinerEngine.minutesToNearestClaim(c), 5)
    }

    func testMinutesToNearestClaim_IgnoresClaimedAndZeroProgressDrops() {
        let c = campaign(id: "c", endsInDays: 5, drops: [
            drop(id: "d1", required: 60, current: 59, claimed: true), // claimed, ignored
            drop(id: "d2", required: 60, current: 0),                 // no progress, ignored
            drop(id: "d3", required: 90, current: 30),                // 60 remaining
        ])
        XCTAssertEqual(MinerEngine.minutesToNearestClaim(c), 60)
    }

    // MARK: - rankCandidates progress tiebreaker

    /// With equal end date and priority, the campaign whose next drop is closer
    /// to completing should sort first — those banked minutes are otherwise at
    /// risk if the game's streams go dark later.
    func testRanking_PrefersCampaignWithNearlyCompleteDrop() {
        let untouched = campaign(id: "c-untouched", endsInDays: 3, drops: [drop(id: "d-u", required: 120)])
        let almostDone = campaign(id: "c-almost", endsInDays: 3, drops: [drop(id: "d-a", required: 120, current: 110)])

        let ranked = MinerEngine.rankCandidates(
            [untouched, almostDone],
            priorityKeys: [], strategy: .mineAll, emptyGameKeys: []
        )
        XCTAssertEqual(ranked.first?.id, "c-almost")
    }

    /// The tiebreaker must not override end date: a sooner-ending campaign still
    /// wins under `.mineAll` even if a later-ending one has more banked progress.
    func testRanking_EndDateStillBeatsProgress() {
        let soonUntouched = campaign(id: "c-soon", endsInDays: 1, drops: [drop(id: "d-s", required: 120)])
        let laterAlmostDone = campaign(id: "c-later", endsInDays: 5, drops: [drop(id: "d-l", required: 120, current: 118)])

        let ranked = MinerEngine.rankCandidates(
            [laterAlmostDone, soonUntouched],
            priorityKeys: [], strategy: .mineAll, emptyGameKeys: []
        )
        XCTAssertEqual(ranked.first?.id, "c-soon")
    }

    // MARK: - shouldDeferPreemption

    func testDeferPreemption_WhenActiveDropNearlyComplete() {
        // 4 minutes left, preemptor ends far in the future → hold and finish.
        XCTAssertTrue(MinerEngine.shouldDeferPreemption(
            remainingMinutesOnActiveDrop: 4,
            preemptorEndDate: now.addingTimeInterval(5 * 86_400),
            now: now
        ))
    }

    func testDeferPreemption_NotWhenActiveDropFarFromDone() {
        // 40 minutes left → let the higher-ranked campaign preempt.
        XCTAssertFalse(MinerEngine.shouldDeferPreemption(
            remainingMinutesOnActiveDrop: 40,
            preemptorEndDate: now.addingTimeInterval(5 * 86_400),
            now: now
        ))
    }

    func testDeferPreemption_NotWhenPreemptorEndsImminently() {
        // Active drop is close, but the preemptor (e.g. a scarce esports window)
        // ends within the hour → take it now rather than strand it.
        XCTAssertFalse(MinerEngine.shouldDeferPreemption(
            remainingMinutesOnActiveDrop: 3,
            preemptorEndDate: now.addingTimeInterval(30 * 60),
            now: now
        ))
    }

    func testDeferPreemption_NotWhenActiveDropProgressUnknown() {
        XCTAssertFalse(MinerEngine.shouldDeferPreemption(
            remainingMinutesOnActiveDrop: nil,
            preemptorEndDate: now.addingTimeInterval(5 * 86_400),
            now: now
        ))
    }

    // MARK: - DropProgressEventTracker.remainingMinutesToNextClaim

    func testTrackerRemainingMinutes_ReflectsMostAdvancedDrop() {
        var tracker = DropProgressEventTracker()
        _ = tracker.observe(DropProgressObservation(
            campaignId: "c1", dropId: "d1", dropLabel: "d1",
            currentMinutes: 20, requiredMinutes: 60, source: .pubSub
        ))
        _ = tracker.observe(DropProgressObservation(
            campaignId: "c1", dropId: "d2", dropLabel: "d2",
            currentMinutes: 55, requiredMinutes: 60, source: .pubSub
        ))
        XCTAssertEqual(tracker.remainingMinutesToNextClaim(campaignId: "c1"), 5)
        XCTAssertNil(tracker.remainingMinutesToNextClaim(campaignId: "other"))
    }

    func testTrackerRemainingMinutes_NilWhenNoProgress() {
        let tracker = DropProgressEventTracker()
        XCTAssertNil(tracker.remainingMinutesToNextClaim(campaignId: "c1"))
    }

    // MARK: - Non-earning campaign cooldown

    func testRegisterGenuineStall_ReachesThresholdAtDefault() {
        var count = 0
        var result = MinerEngine.registerGenuineStall(consecutiveStalls: count)
        XCTAssertEqual(result.updatedCount, 1)
        XCTAssertFalse(result.reachedThreshold)

        count = result.updatedCount
        result = MinerEngine.registerGenuineStall(consecutiveStalls: count)
        XCTAssertEqual(result.updatedCount, 2)
        XCTAssertFalse(result.reachedThreshold)

        count = result.updatedCount
        result = MinerEngine.registerGenuineStall(consecutiveStalls: count)
        XCTAssertEqual(result.updatedCount, 3)
        XCTAssertTrue(result.reachedThreshold, "third consecutive stall should trip the non-earning threshold")
    }

    func testRegisterGenuineStall_RespectsCustomThreshold() {
        let result = MinerEngine.registerGenuineStall(consecutiveStalls: 1, threshold: 2)
        XCTAssertEqual(result.updatedCount, 2)
        XCTAssertTrue(result.reachedThreshold)
    }

    func testIsOnStallCooldown_TrueOnlyWhileActive() {
        let cooldowns = [
            "active": now.addingTimeInterval(600),   // expires in 10m
            "expired": now.addingTimeInterval(-60),  // expired 1m ago
        ]
        XCTAssertTrue(MinerEngine.isOnStallCooldown("active", cooldowns: cooldowns, now: now))
        XCTAssertFalse(MinerEngine.isOnStallCooldown("expired", cooldowns: cooldowns, now: now))
        XCTAssertFalse(MinerEngine.isOnStallCooldown("unknown", cooldowns: cooldowns, now: now))
    }
}
