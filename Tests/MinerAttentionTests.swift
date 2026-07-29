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

    func testHealthyMinerHasNoAttentionPanel() {
        XCTAssertNil(MinerAttentionIssue.resolve(miner: makeMiner(), events: []))
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
