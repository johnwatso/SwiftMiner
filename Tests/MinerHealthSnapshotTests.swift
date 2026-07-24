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
            isHealthy: true
        )
        miner.statusChangedAt = now.addingTimeInterval(-3 * 60 * 60)

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
            isHealthy: true
        )
        miner.statusChangedAt = now.addingTimeInterval(-3 * 60 * 60)

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
            isHealthy: true
        )
        miner.statusChangedAt = now.addingTimeInterval(-3 * 60 * 60)

        XCTAssertFalse(miner.isNotEarning(now: now))
        XCTAssertEqual(MinerHealthSnapshot.make(miner: miner, now: now).health, .mining)
    }

    /// A miner that has never earned is measured from when it started watching, so a freshly
    /// started watch session is not flagged before it has had a chance to bank anything.
    func testFreshWatchSessionWithoutProgressHistoryIsNotFlagged() {
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
            isHealthy: true
        )
        miner.statusChangedAt = now.addingTimeInterval(-5 * 60)

        XCTAssertFalse(miner.isNotEarning(now: now))

        miner.statusChangedAt = now.addingTimeInterval(-25 * 60)
        XCTAssertTrue(miner.isNotEarning(now: now))
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
