import XCTest
import UserNotifications
import SQLite3
@testable import SwiftMiner
@testable import SwiftMinerCore

final class ActivityLogStoreTests: XCTestCase {
    func testOpenRepairsMissingAuditCategorySchemaWhenMigrationIsRecorded() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftMinerActivityLogMigration-\(UUID().uuidString).sqlite")

        var rawDatabase: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &rawDatabase), SQLITE_OK)
        defer {
            if let rawDatabase {
                sqlite3_close(rawDatabase)
            }
        }
        guard let database = rawDatabase else {
            return XCTFail("Expected a temporary SQLite database")
        }

        XCTAssertEqual(sqlite3_exec(database, """
        CREATE TABLE _schema_migrations (version INTEGER PRIMARY KEY);
        INSERT INTO _schema_migrations (version) VALUES (13);
        CREATE TABLE admin_audit_log (
            id TEXT PRIMARY KEY,
            action_type TEXT NOT NULL DEFAULT 'account_assigned',
            operator_id TEXT NOT NULL,
            twitch_id TEXT,
            from_discord_id TEXT,
            to_discord_id TEXT,
            metadata_json TEXT,
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP
        );
        CREATE TABLE activity_log_entries (
            id TEXT PRIMARY KEY,
            timestamp REAL NOT NULL,
            message TEXT NOT NULL,
            level TEXT NOT NULL,
            miner_id TEXT,
            raw_message TEXT,
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP
        );
        INSERT INTO activity_log_entries (id, timestamp, message, level, raw_message)
        VALUES ('audit-entry', 1, 'Gabe signed in', 'info', '[web-audit] Gabe signed in');
        """, nil, nil, nil), SQLITE_OK)
        sqlite3_close(database)
        rawDatabase = nil

        let manager = SQLiteManager(databaseURL: databaseURL)
        try await manager.open()
        addTeardownBlock {
            await manager.close()
            try? FileManager.default.removeItem(at: databaseURL)
        }

        let migrated = try await manager.query { database in
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(
                database,
                "SELECT category FROM activity_log_entries WHERE id = 'audit-entry';",
                -1,
                &statement,
                nil
            ) == SQLITE_OK,
            sqlite3_step(statement) == SQLITE_ROW,
            let category = sqlite3_column_text(statement, 0)
            else { return false }
            return String(cString: category) == "audit"
        }
        await manager.close()

        XCTAssertTrue(migrated, "Audit rows must be protected even after a partial migration")
    }

    func testEntriesRoundTripAcrossStoreInstances() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftMinerActivityLog-\(UUID().uuidString).sqlite")
        let manager = SQLiteManager(databaseURL: databaseURL)
        try await manager.open()
        // Close before unlinking: removing the file while SQLite still has it open makes
        // macOS log "database integrity compromised by API violation". `addTeardownBlock`
        // can await the close, which `defer` cannot.
        addTeardownBlock {
            await manager.close()
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
        addTeardownBlock {
            await manager.close()
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
        addTeardownBlock {
            await manager.close()
            try? FileManager.default.removeItem(at: databaseURL)
        }

        // Floor of zero isolates the plain count-based half of the retention rule.
        let store = ActivityLogStore(manager: manager, maxEntries: 2, perCategoryFloor: 0)
        let oldest = EventEntry(timestamp: Date(timeIntervalSince1970: 100), message: "Oldest", level: .info)
        let middle = EventEntry(timestamp: Date(timeIntervalSince1970: 200), message: "Middle", level: .info)
        let newest = EventEntry(timestamp: Date(timeIntervalSince1970: 300), message: "Newest", level: .info)

        await store.save(oldest)
        await store.save(middle)
        await store.save(newest)
        // Pruning is periodic now rather than once per insert, so ask for it directly.
        await store.prune()

        let entries = await store.loadEntries(limit: 10)
        XCTAssertEqual(entries, [newest, middle])
    }

    /// The reported bug: on a five-miner instance routine chatter is ~99.9% of the
    /// volume, so pruning by recency alone deleted every audit entry within the hour
    /// and selecting the Audit filter showed nothing at all.
    func testRareCategoriesSurviveAFloodOfRoutineChatter() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftMinerActivityLog-\(UUID().uuidString).sqlite")
        let manager = SQLiteManager(databaseURL: databaseURL)
        try await manager.open()
        addTeardownBlock {
            await manager.close()
            try? FileManager.default.removeItem(at: databaseURL)
        }

        let store = ActivityLogStore(manager: manager, maxEntries: 50, perCategoryFloor: 5)

        // Three audit entries, then far more recent chatter than the overall cap.
        for index in 0..<3 {
            await store.save(EventEntry(
                timestamp: Date(timeIntervalSince1970: Double(100 + index)),
                message: "[web-audit] operator action \(index)",
                level: .info,
                category: "audit"
            ))
        }
        for index in 0..<200 {
            await store.save(EventEntry(
                timestamp: Date(timeIntervalSince1970: Double(1_000 + index)),
                message: "Checking game \(index)",
                level: .info,
                category: "scan"
            ))
        }
        await store.prune()

        let entries = await store.loadEntries(limit: 50)
        let audit = entries.filter { $0.category == "audit" }
        XCTAssertEqual(audit.count, 3, "audit entries must outlive newer routine chatter")

        // And the chatter is still bounded rather than growing without limit.
        let scan = entries.filter { $0.category == "scan" }
        XCTAssertLessThanOrEqual(scan.count, 50)
    }

    /// Narrowing the Activity Log to a single filter should fill it, not run dry after a
    /// few hundred rows. Each category is retained up to the configured size, so an
    /// audit-only view is limited by how many audit events exist, not by the chatter
    /// that happened to be logged alongside them.
    @MainActor
    func testASingleFilterFillsToTheConfiguredCapacity() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftMinerAuditFill-\(UUID().uuidString).sqlite")
        let manager = SQLiteManager(databaseURL: databaseURL)
        try await manager.open()
        addTeardownBlock {
            await manager.close()
            try? FileManager.default.removeItem(at: databaseURL)
        }

        let capacity = 300
        let store = ActivityLogStore(manager: manager, maxEntries: capacity, perCategoryFloor: capacity)

        // Audit events scattered through history, each buried under routine chatter.
        var stamp = 0.0
        for index in 0..<400 {
            stamp += 1
            await store.save(EventEntry(
                timestamp: Date(timeIntervalSince1970: stamp),
                message: "[web-audit] action \(index)",
                level: .info,
                category: "audit"
            ))
            for _ in 0..<10 {
                stamp += 1
                await store.save(EventEntry(
                    timestamp: Date(timeIntervalSince1970: stamp),
                    message: "Checking game",
                    level: .info,
                    category: "scan"
                ))
            }
        }
        await store.prune()

        let loaded = await store.loadEntries(limit: capacity)
        let audit = loaded.filter { $0.category == "audit" }
        XCTAssertEqual(audit.count, capacity, "audit history should fill the configured capacity")

        let page = activityLogPage(
            events: loaded,
            selectedFilters: [.audit],
            selectedMinerID: nil,
            searchText: "",
            minerNamesByID: [:],
            limit: 250
        )
        XCTAssertEqual(page.entries.count, 250, "an audit-only view should render a full page")
        XCTAssertTrue(page.hasMore, "and offer the rest behind Load More")
    }

    /// `maxLogEntries` was written and backed up but never read before 1.37, so every
    /// existing install has a stored 500 that nobody chose. Honouring it verbatim when
    /// the setting was finally wired up would have cut retention from 5,000 to 500 —
    /// the opposite of the reported problem.
    @MainActor
    func testLegacyStoredRetentionCannotShrinkHistory() {
        let settings = Settings.shared
        let previous = settings.maxLogEntries
        defer { settings.maxLogEntries = previous }

        Settings.appStorageStore.set(500, forKey: "maxLogEntries")
        XCTAssertGreaterThanOrEqual(settings.maxLogEntries, Settings.minLogEntries)

        settings.maxLogEntries = 10
        XCTAssertGreaterThanOrEqual(settings.maxLogEntries, Settings.minLogEntries)

        settings.maxLogEntries = 20_000
        XCTAssertEqual(settings.maxLogEntries, 20_000, "a real choice is honoured")
    }

    @MainActor
    func testRetentionChoicesAreAllUsable() {
        for choice in Settings.logEntryChoices {
            XCTAssertGreaterThanOrEqual(choice, Settings.minLogEntries)
        }
        XCTAssertTrue(Settings.logEntryChoices.contains(Settings.defaultLogEntries))
    }

    @MainActor
    func testInMemoryRetentionProtectsTheSameCategories() {
        var entries: [EventEntry] = []
        for index in 0..<3 {
            entries.append(EventEntry(
                timestamp: Date(timeIntervalSince1970: Double(100 + index)),
                message: "[web-audit] operator action \(index)",
                level: .info,
                category: "audit"
            ))
        }
        for index in 0..<200 {
            entries.append(EventEntry(
                timestamp: Date(timeIntervalSince1970: Double(1_000 + index)),
                message: "Checking game \(index)",
                level: .info,
                category: "scan"
            ))
        }

        let retained = NavigationModel.applyRetention(to: entries, maxEntries: 50, perCategoryFloor: 5)

        XCTAssertEqual(retained.filter { $0.category == "audit" }.count, 3)
        XCTAssertLessThanOrEqual(retained.filter { $0.category == "scan" }.count, 50)
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
        XCTAssertTrue(NavigationModel.shouldRecordActivityLogMessage(
            "[ChannelSelect]   Verification summary: checked=4, noMatch=4, noMatchEvidence=[Example: Twitch reports no active Drops campaigns]",
            level: .info
        ))
        XCTAssertFalse(NavigationModel.shouldRecordActivityLogMessage(
            "No claimable drops found in inventory",
            level: .info
        ))
        XCTAssertFalse(NavigationModel.shouldRecordActivityLogMessage(
            "Watch heartbeat sent for aspen via Spade",
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

    func testActivityLogPageCapsInitialRenderingAndReportsOlderMatches() {
        let events = (0..<300).map { index in
            EventEntry(
                timestamp: Date(timeIntervalSince1970: TimeInterval(1_000 - index)),
                message: "System event \(index)",
                level: .info
            )
        }

        let page = activityLogPage(
            events: events,
            selectedFilters: [.system],
            selectedMinerID: nil,
            searchText: "",
            minerNamesByID: [:],
            limit: 250
        )

        XCTAssertEqual(page.entries.count, 250)
        XCTAssertEqual(page.entries.first?.message, "System event 0")
        XCTAssertEqual(page.entries.last?.message, "System event 249")
        XCTAssertTrue(page.hasMore)
    }

    func testActivityLogPageFiltersBeforeApplyingItsLimit() {
        let events = [
            EventEntry(message: "System event", level: .info, minerId: "miner-a"),
            EventEntry(message: "Drop claimed", level: .info, minerId: "miner-b"),
            EventEntry(message: "Another drop claimed", level: .info, minerId: "miner-b")
        ]

        let page = activityLogPage(
            events: events,
            selectedFilters: [.drops],
            selectedMinerID: "miner-b",
            searchText: "another",
            minerNamesByID: ["miner-b": "Gabe"],
            limit: 1
        )

        XCTAssertEqual(page.entries.map(\.message), ["Another drop claimed"])
        XCTAssertFalse(page.hasMore)
    }

    func testSubscriptionRequiredActivityUsesMiningFilter() {
        let entry = EventEntry(
            message: "Subscription required: Example Game has drops that require purchasing Twitch subscriptions: Example reward. These drops are being skipped.",
            level: .warning
        )

        let miningPage = activityLogPage(
            events: [entry],
            selectedFilters: [.mining],
            selectedMinerID: nil,
            searchText: "",
            minerNamesByID: [:],
            limit: 10
        )
        let warningPage = activityLogPage(
            events: [entry],
            selectedFilters: [.warnings],
            selectedMinerID: nil,
            searchText: "",
            minerNamesByID: [:],
            limit: 10
        )

        XCTAssertEqual(miningPage.entries, [entry])
        XCTAssertTrue(warningPage.entries.isEmpty)
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
