import XCTest
@testable import SwiftMiner
@testable import SwiftMinerCore

final class ActivityLogStoreTests: XCTestCase {
    func testPersistentAuditEntriesRoundTripAndIgnoreNonAuditRows() async throws {
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
        let entries = await reloadedStore.loadPersistentAuditEntries(limit: 10)

        XCTAssertEqual(entries, [auditEntry])
    }

    func testClearPersistentAuditEntriesRemovesOnlyAuditRows() async throws {
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
        await store.clearPersistentAuditEntries()

        let entries = await store.loadPersistentAuditEntries(limit: 10)
        XCTAssertTrue(entries.isEmpty)
    }
}
