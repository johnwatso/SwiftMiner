import XCTest
@testable import SwiftMinerCore

final class UnattendedHealthStoreTests: XCTestCase {
    func testHealthFactsPersistAcrossStoreInstances() async throws {
        let fileURL = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let progressAt = Date(timeIntervalSince1970: 1_800_000_000)
        let twitchAt = progressAt.addingTimeInterval(30)
        let store = UnattendedHealthStore(fileURL: fileURL)

        try await store.record(.minerObserved(minerID: "miner-1", displayName: "Primary", at: progressAt))
        try await store.record(.miningProgressObserved(minerID: "miner-1", at: progressAt))
        try await store.record(.twitchResponseSucceeded(minerID: "miner-1", at: twitchAt))

        let reloaded = UnattendedHealthStore(fileURL: fileURL)
        let snapshot = await reloaded.snapshot(for: "miner-1")

        XCTAssertEqual(snapshot?.displayName, "Primary")
        XCTAssertEqual(snapshot?.lastMiningProgressAt, progressAt)
        XCTAssertEqual(snapshot?.lastTwitchResponseAt, twitchAt)
        XCTAssertEqual(snapshot?.operatingNormallySince, progressAt)
    }

    func testRepeatedIncidentObservationKeepsStableIdentityAndNotificationState() async throws {
        let fileURL = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let openedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let observedAgainAt = openedAt.addingTimeInterval(60)
        let notifiedAt = openedAt.addingTimeInterval(10)
        let store = UnattendedHealthStore(fileURL: fileURL)

        try await store.record(.incidentObserved(
            minerID: "miner-1",
            kind: .authenticationExpired,
            severity: .critical,
            summary: "Twitch authentication expired",
            recommendedAction: "Sign in again",
            at: openedAt
        ))
        try await store.record(.notificationSent(
            minerID: "miner-1",
            kind: .authenticationExpired,
            at: notifiedAt
        ))
        try await store.record(.incidentObserved(
            minerID: "miner-1",
            kind: .authenticationExpired,
            severity: .critical,
            summary: "Authentication is still required",
            recommendedAction: "Sign in again",
            at: observedAgainAt
        ))

        let incident = await store.snapshot(for: "miner-1")?.activeIncident
        XCTAssertEqual(incident?.id, "miner-1:authenticationExpired")
        XCTAssertEqual(incident?.openedAt, openedAt)
        XCTAssertEqual(incident?.lastObservedAt, observedAgainAt)
        XCTAssertEqual(incident?.notificationSentAt, notifiedAt)
        XCTAssertEqual(incident?.summary, "Authentication is still required")
    }

    func testResolvingIncidentArchivesItAndStartsHealthyDuration() async throws {
        let fileURL = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let openedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let resolvedAt = openedAt.addingTimeInterval(120)
        let store = UnattendedHealthStore(fileURL: fileURL)

        try await store.record(.incidentObserved(
            minerID: "miner-1",
            kind: .progressStalled,
            severity: .warning,
            summary: "No progress",
            recommendedAction: nil,
            at: openedAt
        ))
        try await store.record(.incidentResolved(
            minerID: "miner-1",
            kind: .progressStalled,
            at: resolvedAt
        ))

        let snapshot = await store.snapshot(for: "miner-1")
        let incidents = await store.incidents()
        XCTAssertNil(snapshot?.activeIncident)
        XCTAssertEqual(snapshot?.operatingNormallySince, resolvedAt)
        XCTAssertEqual(incidents.count, 1)
        XCTAssertEqual(incidents.first?.resolvedAt, resolvedAt)
    }

    func testResolvingActiveIncidentDoesNotRequireCallerToKnowItsKind() async throws {
        let fileURL = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let openedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let resolvedAt = openedAt.addingTimeInterval(30)
        let store = UnattendedHealthStore(fileURL: fileURL)

        try await store.record(.incidentObserved(
            minerID: "miner-1",
            kind: .accountLinkRequired,
            severity: .warning,
            summary: "Link required",
            recommendedAction: nil,
            at: openedAt
        ))
        try await store.record(.activeIncidentResolved(minerID: "miner-1", at: resolvedAt))

        let snapshot = await store.snapshot(for: "miner-1")
        let incidents = await store.incidents()
        XCTAssertNil(snapshot?.activeIncident)
        XCTAssertEqual(incidents.first?.kind, .accountLinkRequired)
        XCTAssertEqual(incidents.first?.resolvedAt, resolvedAt)
    }

    func testRecoveryOutcomeIsPersistedAndAddedToBoundedHistory() async throws {
        let fileURL = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let finishedAt = startedAt.addingTimeInterval(15)
        let store = UnattendedHealthStore(fileURL: fileURL, maxRecoveryHistoryPerMiner: 1)

        try await store.record(.recoveryStarted(
            minerID: "miner-1",
            stage: .channelSwitch,
            detail: "Trying another channel",
            at: startedAt
        ))
        try await store.record(.recoveryFinished(
            minerID: "miner-1",
            stage: .channelSwitch,
            succeeded: true,
            detail: "Progress resumed",
            at: finishedAt
        ))

        let snapshot = await store.snapshot(for: "miner-1")
        let history = await store.recoveries(for: "miner-1")
        XCTAssertEqual(snapshot?.lastRecovery?.startedAt, startedAt)
        XCTAssertEqual(snapshot?.lastRecovery?.finishedAt, finishedAt)
        XCTAssertEqual(snapshot?.lastRecovery?.succeeded, true)
        XCTAssertEqual(snapshot?.operatingNormallySince, finishedAt)
        XCTAssertEqual(history, [snapshot?.lastRecovery].compactMap { $0 })
    }

    func testSummaryUsesNewestSharedHealthyStartAndLatestFacts() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let olderRecovery = RecoveryRecord(
            stage: .campaignRefresh,
            startedAt: base,
            finishedAt: base.addingTimeInterval(5),
            succeeded: true
        )
        let newerRecovery = RecoveryRecord(
            stage: .workerRestart,
            startedAt: base.addingTimeInterval(60),
            finishedAt: base.addingTimeInterval(70),
            succeeded: true
        )
        let summary = UnattendedHealthSummary(snapshots: [
            UnattendedHealthSnapshot(
                id: "one",
                displayName: "One",
                lastMiningProgressAt: base.addingTimeInterval(30),
                lastTwitchResponseAt: base.addingTimeInterval(40),
                lastRecovery: olderRecovery,
                operatingNormallySince: base.addingTimeInterval(10),
                updatedAt: base.addingTimeInterval(40)
            ),
            UnattendedHealthSnapshot(
                id: "two",
                displayName: "Two",
                lastMiningProgressAt: base.addingTimeInterval(80),
                lastTwitchResponseAt: base.addingTimeInterval(90),
                lastRecovery: newerRecovery,
                operatingNormallySince: base.addingTimeInterval(20),
                updatedAt: base.addingTimeInterval(90)
            )
        ])

        XCTAssertEqual(summary.operatingNormallySince, base.addingTimeInterval(20))
        XCTAssertEqual(summary.lastMiningProgressAt, base.addingTimeInterval(80))
        XCTAssertEqual(summary.lastTwitchResponseAt, base.addingTimeInterval(90))
        XCTAssertEqual(summary.lastRecovery, newerRecovery)
        XCTAssertTrue(summary.activeIncidents.isEmpty)
    }

    private func temporaryStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftMinerUnattendedHealth-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("health.json")
    }
}
