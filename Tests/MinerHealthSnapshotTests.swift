import XCTest
@testable import SwiftMinerCore

@MainActor
final class MinerHealthSnapshotTests: XCTestCase {
    func testHealthSnapshotComputesStallConfidenceFromSignals() {
        let now = Date(timeIntervalSince1970: 10_000)
        let miner = MinerManager.ManagedMiner(
            id: "miner",
            accountId: "account",
            username: "tester",
            status: .watching,
            isRunning: true,
            priorityGames: [],
            lastEventAt: now.addingTimeInterval(-25 * 60),
            lastSuccessfulPollAt: now.addingTimeInterval(-16 * 60),
            isHealthy: false
        )

        let snapshot = MinerHealthSnapshot.make(miner: miner, now: now)

        XCTAssertEqual(snapshot.health, .attention)
        XCTAssertGreaterThanOrEqual(snapshot.stallConfidencePercent, 75)
        XCTAssertTrue(snapshot.stallSignals.contains("No successful poll in 15m"))
    }

    func testRefreshingMinerWithStaleLivenessKeepsRefreshStatus() {
        let now = Date(timeIntervalSince1970: 10_000)
        let miner = MinerManager.ManagedMiner(
            id: "miner",
            accountId: "account",
            username: "tester",
            status: .fetchingCampaigns,
            isRunning: true,
            priorityGames: [],
            lastEventAt: now.addingTimeInterval(-25 * 60),
            lastSuccessfulPollAt: now.addingTimeInterval(-16 * 60),
            isHealthy: false
        )

        let snapshot = MinerHealthSnapshot.make(miner: miner, now: now)

        XCTAssertEqual(snapshot.health, .idle)
        XCTAssertEqual(snapshot.statusLabel, "Waiting — Refreshing campaigns")
        XCTAssertFalse(snapshot.stallSignals.contains("No recent healthy activity"))
    }

    /// The 1.34.1 failure mode: every liveness probe is green while the account earns nothing.
    func testWatchingWithoutDropProgressRaisesEarningSignal() {
        let now = Date(timeIntervalSince1970: 10_000)
        var miner = MinerManager.ManagedMiner(
            id: "miner",
            accountId: "account",
            username: "tester",
            status: .watching,
            isRunning: true,
            priorityGames: [],
            lastEventAt: now.addingTimeInterval(-30),
            lastSuccessfulPollAt: now.addingTimeInterval(-30),
            lastDropProgressAt: now.addingTimeInterval(-45 * 60),
            workerStartedAt: now.addingTimeInterval(-3 * 60 * 60),
            isHealthy: true
        )
        miner.statusChangedAt = now.addingTimeInterval(-2 * 60)

        let snapshot = MinerHealthSnapshot.make(miner: miner, now: now)

        XCTAssertEqual(snapshot.health, .attention)
        XCTAssertGreaterThanOrEqual(snapshot.stallConfidencePercent, 60)
        XCTAssertTrue(snapshot.stallSignals.contains("Watching with no drop progress in 45m"))
        XCTAssertEqual(snapshot.statusLabel, "Watching — Not Earning")
    }

    func testRecentDropProgressKeepsWatchingMinerHealthy() {
        let now = Date(timeIntervalSince1970: 10_000)
        var miner = MinerManager.ManagedMiner(
            id: "miner",
            accountId: "account",
            username: "tester",
            status: .watching,
            isRunning: true,
            priorityGames: [],
            lastEventAt: now.addingTimeInterval(-30),
            lastSuccessfulPollAt: now.addingTimeInterval(-30),
            lastDropProgressAt: now.addingTimeInterval(-4 * 60),
            workerStartedAt: now.addingTimeInterval(-3 * 60 * 60),
            isHealthy: true
        )
        miner.statusChangedAt = now.addingTimeInterval(-2 * 60)

        let snapshot = MinerHealthSnapshot.make(miner: miner, now: now)

        XCTAssertEqual(snapshot.health, .mining)
        XCTAssertTrue(snapshot.stallSignals.isEmpty)
    }

    /// A pinned stream is expected to sit on a channel that may never earn, so it must not
    /// be reported as a fault.
    func testStreamOverrideIsExemptFromEarningSignal() {
        let now = Date(timeIntervalSince1970: 10_000)
        var miner = MinerManager.ManagedMiner(
            id: "miner",
            accountId: "account",
            username: "tester",
            status: .watching,
            streamOverrideLogin: "flats",
            isRunning: true,
            priorityGames: [],
            lastEventAt: now.addingTimeInterval(-30),
            lastSuccessfulPollAt: now.addingTimeInterval(-30),
            lastDropProgressAt: now.addingTimeInterval(-3 * 60 * 60),
            workerStartedAt: now.addingTimeInterval(-3 * 60 * 60),
            isHealthy: true
        )
        miner.statusChangedAt = now.addingTimeInterval(-2 * 60)

        XCTAssertFalse(miner.isNotEarning(now: now))
        XCTAssertEqual(MinerHealthSnapshot.make(miner: miner, now: now).health, .mining)
    }

    /// A miner that has never earned is measured from when its worker started, so a freshly
    /// started session is not flagged before it has had a chance to bank anything.
    func testFreshSessionWithoutProgressHistoryIsNotFlagged() {
        let now = Date(timeIntervalSince1970: 10_000)
        var miner = MinerManager.ManagedMiner(
            id: "miner",
            accountId: "account",
            username: "tester",
            status: .watching,
            isRunning: true,
            priorityGames: [],
            lastEventAt: now.addingTimeInterval(-30),
            lastSuccessfulPollAt: now.addingTimeInterval(-30),
            workerStartedAt: now.addingTimeInterval(-5 * 60),
            isHealthy: true
        )

        XCTAssertFalse(miner.isNotEarning(now: now))

        miner.workerStartedAt = now.addingTimeInterval(-25 * 60)
        XCTAssertTrue(miner.isNotEarning(now: now))
    }

    /// Regression for the defect that made the shipped check dead on arrival: normal mining
    /// cycles watching -> refreshing -> watching every few minutes, and anchoring on
    /// statusChangedAt reset the clock every cycle so the threshold was never reached.
    /// A miner that has churned status for hours without earning must still be flagged.
    func testStatusChurnDoesNotResetTheEarningClock() {
        let now = Date(timeIntervalSince1970: 10_000)
        var miner = MinerManager.ManagedMiner(
            id: "miner",
            accountId: "account",
            username: "tester",
            status: .watching,
            isRunning: true,
            priorityGames: [],
            lastEventAt: now.addingTimeInterval(-5),
            lastSuccessfulPollAt: now.addingTimeInterval(-5),
            workerStartedAt: now.addingTimeInterval(-6 * 60 * 60),
            isHealthy: true
        )
        // Re-entered .watching a minute ago, as it does on every mining cycle.
        miner.statusChangedAt = now.addingTimeInterval(-60)

        XCTAssertTrue(miner.isNotEarning(now: now))
        XCTAssertEqual(MinerHealthSnapshot.make(miner: miner, now: now).health, .attention)
    }

    /// Without a worker start or any banked progress there is no honest way to say how long
    /// the miner has gone without earning, so it must not be flagged on a guess.
    func testMinerWithNoTimingAnchorIsNotFlagged() {
        let now = Date(timeIntervalSince1970: 10_000)
        let miner = MinerManager.ManagedMiner(
            id: "miner",
            accountId: "account",
            username: "tester",
            status: .watching,
            isRunning: true,
            isHealthy: true
        )

        XCTAssertFalse(miner.isNotEarning(now: now))
    }
}

@MainActor
final class WatchTimeAccumulationTests: XCTestCase {
    private func watchingMiner(id: String = "miner") -> MinerManager.ManagedMiner {
        MinerManager.ManagedMiner(
            id: id,
            accountId: "account",
            username: "tester",
            status: .watching,
            isRunning: true
        )
    }

    /// The first observation only sets the anchor — there is no earlier point to measure from,
    /// so nothing is credited and the clock starts.
    func testFirstObservationOnlyAnchorsTheClock() {
        let manager = MinerManager(clientId: "test")
        let now = Date(timeIntervalSince1970: 10_000)

        manager.accumulateWatchTime(for: watchingMiner(), now: now)

        XCTAssertEqual(manager.lastWatchSampleAt["miner"], now)
    }

    /// Bursts of snapshots inside the batching window leave the anchor alone, so the elapsed
    /// time is credited once rather than per snapshot.
    func testRapidObservationsDoNotAdvanceTheAnchor() {
        let manager = MinerManager(clientId: "test")
        let now = Date(timeIntervalSince1970: 10_000)
        let miner = watchingMiner()

        manager.accumulateWatchTime(for: miner, now: now)
        manager.accumulateWatchTime(for: miner, now: now.addingTimeInterval(1))
        manager.accumulateWatchTime(for: miner, now: now.addingTimeInterval(5))

        XCTAssertEqual(manager.lastWatchSampleAt["miner"], now)

        manager.accumulateWatchTime(for: miner, now: now.addingTimeInterval(20))
        XCTAssertEqual(manager.lastWatchSampleAt["miner"], now.addingTimeInterval(20))
    }

    /// A long gap means the app slept or the miner went quiet. The clock restarts so the next
    /// stretch is measured correctly, but the gap itself is never credited as watching.
    func testLongGapRestartsTheClockWithoutCrediting() {
        let manager = MinerManager(clientId: "test")
        let now = Date(timeIntervalSince1970: 10_000)
        let miner = watchingMiner()

        manager.accumulateWatchTime(for: miner, now: now)
        let afterSleep = now.addingTimeInterval(6 * 60 * 60)
        manager.accumulateWatchTime(for: miner, now: afterSleep)

        XCTAssertEqual(manager.lastWatchSampleAt["miner"], afterSleep)
    }

    func testLeavingWatchingClearsTheAnchor() {
        let manager = MinerManager(clientId: "test")
        let now = Date(timeIntervalSince1970: 10_000)

        manager.accumulateWatchTime(for: watchingMiner(), now: now)
        XCTAssertNotNil(manager.lastWatchSampleAt["miner"])

        var idle = watchingMiner()
        idle.status = .idleNoEligibleCampaigns
        manager.accumulateWatchTime(for: idle, now: now.addingTimeInterval(30))

        XCTAssertNil(manager.lastWatchSampleAt["miner"])
    }
}
