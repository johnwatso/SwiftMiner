import XCTest
@testable import SwiftMiner
@testable import SwiftMinerCore

@MainActor
final class MinerFleetStatusTests: XCTestCase {
    func testHealthLabelsDescribeConditionInsteadOfActivity() {
        XCTAssertEqual(MinerFleetStatus.title(for: .idle), "Healthy")
        XCTAssertEqual(MinerFleetStatus.title(for: .mining), "Healthy")
        XCTAssertEqual(MinerFleetStatus.title(for: .recovering), "Recovering")
        XCTAssertEqual(MinerFleetStatus.title(for: .attention), "Warning")
        for health: MinerHealthSnapshot.Health in [.stalled, .needsAuth, .blocked] {
            XCTAssertEqual(MinerFleetStatus.title(for: health), "Error")
        }
    }

    func testEmptyFleetDoesNotClaimToBeHealthy() {
        XCTAssertEqual(MinerFleetStatus.make(miners: []).healthTitle, "No Miners")
    }

    func testIdleFleetIsHealthyAndAnAuthenticationFaultWins() {
        let idle = MinerManager.ManagedMiner(
            id: "idle", accountId: "idle", username: "idle", status: .idle,
            isRunning: false, priorityGames: []
        )
        let failed = MinerManager.ManagedMiner(
            id: "failed", accountId: "failed", username: "failed", status: .idle,
            needsAuth: true, isRunning: false, priorityGames: []
        )
        XCTAssertEqual(MinerFleetStatus.make(miners: [idle]).healthTitle, "Healthy")
        XCTAssertEqual(MinerFleetStatus.make(miners: [idle]).healthSymbol, "checkmark.circle.fill")
        XCTAssertEqual(MinerFleetStatus.make(miners: [idle, failed]).healthTitle, "Error")
        XCTAssertEqual(MinerFleetStatus.make(miners: [failed, idle]).healthTitle, "Error")
    }
}
