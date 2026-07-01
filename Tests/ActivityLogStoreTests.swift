import XCTest
import UserNotifications
@testable import SwiftMiner
@testable import SwiftMinerCore

final class ActivityLogStoreTests: XCTestCase {
    func testEntriesRoundTripAcrossStoreInstances() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftMinerActivityLog-\(UUID().uuidString).sqlite")
        let manager = SQLiteManager(databaseURL: databaseURL)
        try await manager.open()
        defer {
            Task { await manager.close() }
            try? FileManager.default.removeItem(at: databaseURL)
        }

        let store = ActivityLogStore(manager: manager)
        let auditEntry = EventEntry(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 1_800_000_000),
            message: "Gabe signed in to the web dashboard",
            level: .info,
            rawMessage: "[web-audit] Gabe signed in to the web dashboard"
        )
        let nonAuditEntry = EventEntry(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 1_800_000_100),
            message: "API server listening on port 8080",
            level: .info,
            rawMessage: nil
        )

        await store.save(auditEntry)
        await store.save(nonAuditEntry)

        let reloadedStore = ActivityLogStore(manager: manager)
        let entries = await reloadedStore.loadEntries(limit: 10)

        XCTAssertEqual(entries, [nonAuditEntry, auditEntry])
    }

    func testClearRemovesAllPersistentEntries() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftMinerActivityLog-\(UUID().uuidString).sqlite")
        let manager = SQLiteManager(databaseURL: databaseURL)
        try await manager.open()
        defer {
            Task { await manager.close() }
            try? FileManager.default.removeItem(at: databaseURL)
        }

        let store = ActivityLogStore(manager: manager)
        await store.save(EventEntry(message: "Audit", level: .info, rawMessage: "[web-audit] Audit"))
        await store.save(EventEntry(message: "Update", level: .info, rawMessage: "[update] Update"))
        await store.clear()

        let entries = await store.loadEntries(limit: 10)
        XCTAssertTrue(entries.isEmpty)
    }

    func testStorePrunesOldestEntriesToRetentionLimit() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftMinerActivityLog-\(UUID().uuidString).sqlite")
        let manager = SQLiteManager(databaseURL: databaseURL)
        try await manager.open()
        defer {
            Task { await manager.close() }
            try? FileManager.default.removeItem(at: databaseURL)
        }

        let store = ActivityLogStore(manager: manager, maxEntries: 2)
        let oldest = EventEntry(timestamp: Date(timeIntervalSince1970: 100), message: "Oldest", level: .info)
        let middle = EventEntry(timestamp: Date(timeIntervalSince1970: 200), message: "Middle", level: .info)
        let newest = EventEntry(timestamp: Date(timeIntervalSince1970: 300), message: "Newest", level: .info)

        await store.save(oldest)
        await store.save(middle)
        await store.save(newest)

        let entries = await store.loadEntries(limit: 10)
        XCTAssertEqual(entries, [newest, middle])
    }

    func testNoisyDiagnosticInfoLogsAreNotRecordedInActivityLog() {
        XCTAssertFalse(NavigationModel.shouldRecordActivityLogMessage(
            "  · EMPULSE Drops (EMPULSE) → Status: AVAILABLE → Relevance: IRRELEVANT",
            level: .info
        ))
        XCTAssertFalse(NavigationModel.shouldRecordActivityLogMessage(
            "[CampaignSelect]   Filtered out 100 campaigns: unlinked_not_prioritised",
            level: .info
        ))
        XCTAssertFalse(NavigationModel.shouldRecordActivityLogMessage(
            "[ChannelSelect]     None of our candidates active here. Channel drops:",
            level: .info
        ))
        XCTAssertFalse(NavigationModel.shouldRecordActivityLogMessage(
            "No claimable drops found in inventory",
            level: .info
        ))
        XCTAssertFalse(NavigationModel.shouldRecordActivityLogMessage(
            "Watch heartbeat sent for aspen via Twitch GQL",
            level: .info
        ))

        XCTAssertTrue(NavigationModel.shouldRecordActivityLogMessage(
            "Progress +3 min on Season 3 Lootbox (385/480 min)",
            level: .info
        ))
        XCTAssertTrue(NavigationModel.shouldRecordActivityLogMessage(
            "Subscription required: Example has drops that require purchasing Twitch subscriptions.",
            level: .warning
        ))
    }

    func testUpdateCompletionNotificationUsesIndependentCategory() {
        let update = NavigationModel.CompletedUpdate(
            previousVersion: "1.31",
            currentVersion: "1.31.1",
            currentBuild: "2026062410"
        )

        let request = UpdateCompletionNotification.makeRequest(for: update)

        XCTAssertEqual(request.identifier, "swiftminer-update-1.31.1-2026062410")
        XCTAssertEqual(request.content.title, "SwiftMiner Updated")
        XCTAssertEqual(request.content.body, "Updated to 1.31.1. Mining resumed automatically.")
        XCTAssertEqual(request.content.categoryIdentifier, "app_update_completed")
        XCTAssertNotNil(request.content.sound)
    }
}
