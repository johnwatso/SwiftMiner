import UserNotifications
import XCTest
@testable import SwiftMinerCore

final class UnattendedIncidentNotificationServiceTests: XCTestCase {
    func testPendingIncidentIsDeliveredOnceAndMarkedSent() async throws {
        let fileURL = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let openedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let notifiedAt = openedAt.addingTimeInterval(30)
        let store = UnattendedHealthStore(fileURL: fileURL)
        try await store.record(.minerObserved(
            minerID: "miner-1",
            displayName: "Primary",
            at: openedAt
        ))
        try await store.record(.incidentObserved(
            minerID: "miner-1",
            kind: .authenticationExpired,
            severity: .critical,
            summary: "Twitch authentication expired",
            recommendedAction: "Sign in to Twitch again",
            at: openedAt
        ))

        let center = MockNotificationCenter()
        let service = UnattendedIncidentNotificationService(
            store: store,
            center: center,
            now: { notifiedAt }
        )

        await service.deliverPendingNotifications()
        await service.deliverPendingNotifications()

        XCTAssertEqual(center.requests.count, 1)
        XCTAssertEqual(center.requests.first?.identifier, "swiftminer-health-miner-1:authenticationExpired")
        XCTAssertEqual(center.requests.first?.content.title, "Twitch Sign-In Required")
        XCTAssertEqual(
            center.requests.first?.content.body,
            "Primary: Twitch authentication expired. Sign in to Twitch again."
        )
        let incident = await store.snapshot(for: "miner-1")?.activeIncident
        XCTAssertEqual(incident?.notificationSentAt, notifiedAt)
    }

    func testFailedDeliveryRemainsPendingForRetry() async throws {
        let fileURL = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let store = UnattendedHealthStore(fileURL: fileURL)
        try await store.record(.incidentObserved(
            minerID: "miner-1",
            kind: .progressStalled,
            severity: .warning,
            summary: "Progress stopped",
            recommendedAction: "Review miner diagnostics",
            at: Date()
        ))

        let center = MockNotificationCenter()
        center.error = TestError.deliveryFailed
        let service = UnattendedIncidentNotificationService(store: store, center: center)
        await service.deliverPendingNotifications()

        let incident = await store.snapshot(for: "miner-1")?.activeIncident
        XCTAssertNil(incident?.notificationSentAt)
    }

    func testOptionalAccountLinkIncidentDoesNotSendAssuranceAlert() async throws {
        let fileURL = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let store = UnattendedHealthStore(fileURL: fileURL)
        try await store.record(.incidentObserved(
            minerID: "miner-1",
            kind: .accountLinkRequired,
            severity: .warning,
            summary: "Link required",
            recommendedAction: nil,
            at: Date()
        ))

        let center = MockNotificationCenter()
        let service = UnattendedIncidentNotificationService(store: store, center: center)
        await service.deliverPendingNotifications()

        XCTAssertTrue(center.requests.isEmpty)
    }

    func testNotificationIsDeferredUntilPermissionIsAuthorized() async throws {
        let fileURL = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let store = UnattendedHealthStore(fileURL: fileURL)
        try await store.record(.incidentObserved(
            minerID: "miner-1",
            kind: .recoveryExhausted,
            severity: .critical,
            summary: "Recovery stopped",
            recommendedAction: nil,
            at: Date()
        ))

        let center = MockNotificationCenter()
        center.authorizationStatus = .notDetermined
        let service = UnattendedIncidentNotificationService(store: store, center: center)
        await service.deliverPendingNotifications()

        XCTAssertTrue(center.requests.isEmpty)
        let incident = await store.snapshot(for: "miner-1")?.activeIncident
        XCTAssertNil(incident?.notificationSentAt)
    }

    private enum TestError: Error {
        case deliveryFailed
    }

    private final class MockNotificationCenter: NotificationCenterProtocol, @unchecked Sendable {
        var authorizationStatus: UNAuthorizationStatus = .authorized
        var requests: [UNNotificationRequest] = []
        var error: Error?

        func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
            true
        }

        func notificationSettings() async -> NotificationSettingsProtocol {
            MockNotificationSettings(authorizationStatus: authorizationStatus)
        }

        func add(_ request: UNNotificationRequest) async throws {
            if let error {
                throw error
            }
            requests.append(request)
        }
    }

    private struct MockNotificationSettings: NotificationSettingsProtocol {
        let authorizationStatus: UNAuthorizationStatus
    }

    private func temporaryStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftMinerTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("unattended-health.json")
    }

    /// Not-earning is a diagnostic signal, not an alert. It fires on every miner the moment
    /// a fleet stops earning, and its false-positive rate is still unmeasured, so it must
    /// stay visible-but-silent until the ledger shows it is precise enough to wake someone.
    func testNotEarningIncidentIsRecordedButDoesNotNotify() async throws {
        let fileURL = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let openedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let store = UnattendedHealthStore(fileURL: fileURL)
        try await store.record(.minerObserved(
            minerID: "miner-1",
            displayName: "Primary",
            at: openedAt
        ))
        try await store.record(.incidentObserved(
            minerID: "miner-1",
            kind: .notEarning,
            severity: .warning,
            summary: "Watching for 45 minutes without earning any drop progress",
            recommendedAction: "Check the campaign is still eligible for this account",
            at: openedAt
        ))

        let center = MockNotificationCenter()
        let service = UnattendedIncidentNotificationService(
            store: store,
            center: center,
            now: { openedAt.addingTimeInterval(30) }
        )

        await service.deliverPendingNotifications()

        XCTAssertTrue(center.requests.isEmpty)
        // Still recorded, so the app and the diagnostic report can show it.
        let incident = await store.snapshot(for: "miner-1")?.activeIncident
        XCTAssertEqual(incident?.kind, .notEarning)
        XCTAssertNil(incident?.notificationSentAt)
    }

    /// The supervisor's "miner unresponsive" stall is a different fault and must still alert.
    func testSupervisorProgressStallStillNotifies() async throws {
        let fileURL = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let openedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let store = UnattendedHealthStore(fileURL: fileURL)
        try await store.record(.minerObserved(minerID: "miner-1", displayName: "Primary", at: openedAt))
        try await store.record(.incidentObserved(
            minerID: "miner-1",
            kind: .progressStalled,
            severity: .warning,
            summary: "The miner has stopped reporting healthy activity",
            recommendedAction: "Review miner diagnostics",
            at: openedAt
        ))

        let center = MockNotificationCenter()
        let service = UnattendedIncidentNotificationService(
            store: store,
            center: center,
            now: { openedAt.addingTimeInterval(30) }
        )

        await service.deliverPendingNotifications()

        XCTAssertEqual(center.requests.count, 1)
        XCTAssertEqual(center.requests.first?.content.title, "Mining Progress Stalled")
    }

    /// Notification is driven by the kind's promotion stage, so a newly added signal is
    /// silent by construction rather than by someone remembering to handle it here.
    func testOnlyPromotedSignalsAreAllowedToNotify() {
        XCTAssertEqual(HealthIncident.Kind.notEarning.deliveryStage, .displayed)
        XCTAssertEqual(HealthIncident.Kind.accountLinkRequired.deliveryStage, .displayed)
        XCTAssertEqual(HealthIncident.Kind.other.deliveryStage, .displayed)

        XCTAssertEqual(HealthIncident.Kind.authenticationExpired.deliveryStage, .alerted)
        XCTAssertEqual(HealthIncident.Kind.recoveryExhausted.deliveryStage, .alerted)
        XCTAssertEqual(HealthIncident.Kind.progressStalled.deliveryStage, .alerted)
        XCTAssertEqual(HealthIncident.Kind.webDashboardUnavailable.deliveryStage, .alerted)
        XCTAssertEqual(HealthIncident.Kind.automaticUpdateFailed.deliveryStage, .alerted)
        // Alerted on arrival rather than displayed first, because it is raised only for a
        // Twitch compatibility failure — a query shape that stays broken until SwiftMiner
        // ships a new hash. Silence is the failure it exists to fix: on 2026-08-18 the
        // liveness check failed 266 times with nothing reaching the user, and restricted
        // esports campaigns were undetectable for the duration.
        XCTAssertEqual(HealthIncident.Kind.channelChecksIncompatible.deliveryStage, .alerted)
    }

    func testIncompatibleChannelChecksNotifyWithTheirOwnTitle() async throws {
        let request = UnattendedIncidentNotificationService.makeRequest(
            incident: HealthIncident(
                id: "miner-1-channelChecksIncompatible",
                minerID: "miner-1",
                kind: .channelChecksIncompatible,
                severity: .critical,
                openedAt: Date(),
                lastObservedAt: Date(),
                summary: "Approved-channel liveness checks are failing (3 in a row)",
                recommendedAction: "Point a miner at the channel with Override Stream, or watch it on Twitch — drops still count"
            ),
            displayName: "ruffcrumble"
        )

        XCTAssertEqual(request.content.title, "Esports Campaigns May Be Missed")
    }
}
