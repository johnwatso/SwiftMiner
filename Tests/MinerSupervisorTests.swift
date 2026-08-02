import XCTest
@testable import SwiftMinerCore

final class MinerSupervisorTests: XCTestCase {
    func testNetworkAndRateLimitErrorsAreRetryable() {
        XCTAssertFalse(MinerEngine.shouldReportFatalError(.networkError("The request timed out.")))
        XCTAssertFalse(MinerEngine.shouldReportFatalError(.rateLimited(retryAfter: 30)))
        XCTAssertFalse(MinerEngine.shouldReportFatalError(.apiError(statusCode: 429, message: "slow down")))
        XCTAssertFalse(MinerEngine.shouldReportFatalError(.apiError(statusCode: 503, message: "unavailable")))
        XCTAssertEqual(
            MinerEngine.classifyIssue(TwitchMinerError.apiError(statusCode: 429, message: "slow down")).0,
            .rateLimited
        )
    }

    func testAuthErrorsRemainFatal() {
        XCTAssertTrue(MinerEngine.shouldReportFatalError(.tokenExpired))
        XCTAssertTrue(MinerEngine.shouldReportFatalError(.authenticationFailed("Forbidden")))
    }

    func testCompatibilityErrorsRemainFatalAndAreClassifiedAsTwitchAPIProblems() {
        let error = TwitchMinerError.twitchAPICompatibility(
            operation: "Inventory",
            reason: "Twitch no longer recognises this persisted query."
        )
        XCTAssertTrue(MinerEngine.shouldReportFatalError(error))
        XCTAssertEqual(MinerEngine.classifyIssue(error).0, .twitchAPIFailure)
    }

    @MainActor
    func testRecoveryStagesHaveBoundedDeadlines() {
        XCTAssertEqual(MinerManager.recoveryTimeoutSeconds(for: .refresh), 90)
        XCTAssertEqual(MinerManager.recoveryTimeoutSeconds(for: .restart), 120)
        XCTAssertEqual(MinerManager.recoveryTimeoutSeconds(for: .authRefresh), 120)
    }

    func testPeerPollingMinerMarksSilentMinerStalled() async {
        let supervisor = MinerSupervisor(
            configuration: .init(
                stallTimeout: 60,
                peerFreshnessWindow: 300,
                startupGracePeriod: 10,
                noRecentActivityWindow: 30,
                recoveryBaseCooldown: 10,
                recoveryMaxCooldown: 60
            )
        )

        let now = Date()
        let peer = MinerManager.ManagedMiner(
            id: "peer",
            accountId: "peer-account",
            username: "peer",
            status: .watching,
            isRunning: true
        )
        let stalled = MinerManager.ManagedMiner(
            id: "stalled",
            accountId: "stalled-account",
            username: "stalled",
            status: .idleNoEligibleCampaigns,
            isRunning: true
        )

        await supervisor.registerMiner(peer.id)
        await supervisor.registerMiner(stalled.id)
        await supervisor.recordWorkerStart(minerId: peer.id, taskID: "peer-task", at: now.addingTimeInterval(-120))
        await supervisor.recordWorkerStart(minerId: stalled.id, taskID: "stalled-task", at: now.addingTimeInterval(-120))
        await supervisor.recordSuccessfulPoll(minerId: peer.id, at: now.addingTimeInterval(-5))
        await supervisor.recordStateUpdate(minerId: stalled.id, at: now.addingTimeInterval(-90))

        let snapshots = await supervisor.refreshHealth(for: [peer, stalled], now: now)

        XCTAssertEqual(snapshots["peer"]?.isStalled, false)
        XCTAssertEqual(snapshots["stalled"]?.isStalled, true)
        XCTAssertEqual(snapshots["stalled"]?.isHealthy, false)
    }

    func testSupervisorRecoveryAdvancesThroughStagesWithCooldown() async {
        let supervisor = MinerSupervisor(
            configuration: .init(
                stallTimeout: 60,
                peerFreshnessWindow: 300,
                startupGracePeriod: 0,
                noRecentActivityWindow: 30,
                recoveryBaseCooldown: 10,
                recoveryMaxCooldown: 60
            )
        )

        let base = Date()
        let peer = MinerManager.ManagedMiner(
            id: "peer",
            accountId: "peer-account",
            username: "peer",
            status: .watching,
            isRunning: true
        )
        let stalled = MinerManager.ManagedMiner(
            id: "stalled",
            accountId: "stalled-account",
            username: "stalled",
            status: .idleNoEligibleCampaigns,
            isRunning: true
        )

        await supervisor.registerMiner(peer.id)
        await supervisor.registerMiner(stalled.id)
        await supervisor.recordWorkerStart(minerId: peer.id, taskID: "peer-task", at: base.addingTimeInterval(-180))
        await supervisor.recordWorkerStart(minerId: stalled.id, taskID: "stalled-task", at: base.addingTimeInterval(-180))
        await supervisor.recordSuccessfulPoll(minerId: peer.id, at: base.addingTimeInterval(-5))
        await supervisor.recordStateUpdate(minerId: stalled.id, at: base.addingTimeInterval(-120))

        let first = await supervisor.nextRecoveryAction(for: [peer, stalled], now: base)
        XCTAssertEqual(first?.stage, .refresh)

        await supervisor.noteRecoveryFailure(minerId: stalled.id, stage: .refresh, at: base.addingTimeInterval(1))
        let second = await supervisor.nextRecoveryAction(for: [peer, stalled], now: base.addingTimeInterval(72))
        XCTAssertEqual(second?.stage, .restart)

        await supervisor.noteRecoveryFailure(minerId: stalled.id, stage: .restart, at: base.addingTimeInterval(73))
        let third = await supervisor.nextRecoveryAction(for: [peer, stalled], now: base.addingTimeInterval(154))
        XCTAssertEqual(third?.stage, .authRefresh)
    }

    func testDropProgressIsTrackedSeparatelyFromLiveness() async {
        let supervisor = MinerSupervisor()
        let base = Date(timeIntervalSince1970: 50_000)

        await supervisor.registerMiner("miner")
        await supervisor.recordSuccessfulPoll(minerId: "miner", at: base)

        let beforeProgress = await supervisor.snapshot(for: "miner")
        XCTAssertNotNil(beforeProgress?.lastSuccessfulPollAt)
        XCTAssertNil(beforeProgress?.lastDropProgressAt)

        await supervisor.recordDropProgress(minerId: "miner", at: base.addingTimeInterval(60))

        let afterProgress = await supervisor.snapshot(for: "miner")
        XCTAssertEqual(afterProgress?.lastDropProgressAt, base.addingTimeInterval(60))
        XCTAssertEqual(afterProgress?.lastEventAt, base.addingTimeInterval(60))
    }

    func testSingleMinerUsesConservativeLocalWatchdog() async {
        let supervisor = MinerSupervisor(
            configuration: .init(
                stallTimeout: 60,
                peerFreshnessWindow: 300,
                startupGracePeriod: 0,
                noRecentActivityWindow: 30,
                recoveryBaseCooldown: 10,
                recoveryMaxCooldown: 60,
                localStallTimeout: 180
            )
        )
        let now = Date(timeIntervalSince1970: 50_000)
        let miner = MinerManager.ManagedMiner(
            id: "solo",
            accountId: "solo-account",
            username: "solo",
            status: .watching,
            isRunning: true
        )

        await supervisor.registerMiner(miner.id)
        await supervisor.recordWorkerStart(minerId: miner.id, taskID: "solo-task", at: now.addingTimeInterval(-300))
        await supervisor.recordSuccessfulPoll(minerId: miner.id, at: now.addingTimeInterval(-120))

        var snapshots = await supervisor.refreshHealth(for: [miner], now: now)
        XCTAssertEqual(snapshots[miner.id]?.isStalled, false, "solo watchdog should use the longer local timeout")

        snapshots = await supervisor.refreshHealth(for: [miner], now: now.addingTimeInterval(61))
        XCTAssertEqual(snapshots[miner.id]?.isStalled, true)
        let action = await supervisor.nextRecoveryAction(for: [miner], now: now.addingTimeInterval(61))
        XCTAssertEqual(action?.stage, .refresh)
    }
}
