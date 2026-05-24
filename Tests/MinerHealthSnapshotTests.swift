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
}
