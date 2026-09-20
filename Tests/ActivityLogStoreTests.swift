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

    func testDailyArchiveRotatesAndExportsSevenCalendarDays() async throws {
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftMinerDailyActivity-\(UUID().uuidString)", isDirectory: true)
        let databaseURL = testRoot.appendingPathComponent("activity.sqlite")
        let archiveURL = testRoot.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: true)

        let manager = SQLiteManager(databaseURL: databaseURL)
        try await manager.open()
        addTeardownBlock {
            await manager.close()
            try? FileManager.default.removeItem(at: testRoot)
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let today = calendar.date(from: DateComponents(
            year: 2026,
            month: 9,
            day: 20,
            hour: 12
        ))!
        let store = ActivityLogStore(
            manager: manager,
            archiveDirectoryURL: archiveURL,
            archiveCalendar: calendar,
            archiveRetentionDays: 7
        )

        for daysAgo in (0...7).reversed() {
            let timestamp = calendar.date(byAdding: .day, value: -daysAgo, to: today)!
            await store.save(EventEntry(
                timestamp: timestamp,
                message: "Day -\(daysAgo)\nwith detail",
                level: daysAgo == 0 ? .warning : .info,
                category: "system"
            ))
        }

        let archived = await store.loadArchivedEntries(now: today)
        XCTAssertEqual(archived.count, 7)
        XCTAssertEqual(archived.first?.message, "Day -6\nwith detail")
        XCTAssertEqual(archived.last?.message, "Day -0\nwith detail")
        XCTAssertEqual(archived.last?.level, .warning)

        let files = try FileManager.default.contentsOfDirectory(
            at: archiveURL,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("SwiftMiner-activity-") }
        XCTAssertEqual(files.count, 7)
        XCTAssertFalse(files.contains { $0.lastPathComponent.contains("2026-09-13") })
        XCTAssertTrue(files.contains { $0.lastPathComponent == "SwiftMiner-activity-2026-09-20.log" })
    }

    func testClearingActivityLogAlsoRemovesDailyArchives() async throws {
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftMinerDailyActivityClear-\(UUID().uuidString)", isDirectory: true)
        let databaseURL = testRoot.appendingPathComponent("activity.sqlite")
        let archiveURL = testRoot.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: true)

        let manager = SQLiteManager(databaseURL: databaseURL)
        try await manager.open()
        addTeardownBlock {
            await manager.close()
            try? FileManager.default.removeItem(at: testRoot)
        }

        let store = ActivityLogStore(manager: manager, archiveDirectoryURL: archiveURL)
        await store.save(EventEntry(message: "Archived", level: .info))
        await store.clear()

        let files = try FileManager.default.contentsOfDirectory(
            at: archiveURL,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("SwiftMiner-activity-") }
        let persisted = await store.loadEntries(limit: 10)
        XCTAssertTrue(files.isEmpty)
        XCTAssertTrue(persisted.isEmpty)
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

    @MainActor
    func testNewestFirstRetentionFastPathMatchesGeneralRetention() {
        let entries = (0..<200).map { index in
            EventEntry(
                timestamp: Date(timeIntervalSince1970: Double(index)),
                message: "Event \(index)",
                level: .info,
                category: index.isMultiple(of: 17) ? "audit" : "scan"
            )
        }
        let newestFirst = entries.sorted { $0.timestamp > $1.timestamp }

        XCTAssertEqual(
            NavigationModel.applyRetentionToNewestFirst(
                newestFirst,
                maxEntries: 50,
                perCategoryFloor: 5
            ),
            NavigationModel.applyRetention(
                to: entries,
                maxEntries: 50,
                perCategoryFloor: 5
            )
        )
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

    /// A stall window is only useful read whole: the alarm, the inventory it read, and
    /// the recovery it chose. They used to scatter across Warnings, Mining and System,
    /// so per-category retention evicted the decision within a day and left a log saying
    /// something went wrong but never what was done about it.
    @MainActor
    func testAntiStallWindowFilesEveryLineUnderWarnings() {
        let tag = MinerEngine.antiStallLogTag
        let window: [(String, EventLevel)] = [
            ("\(tag) Progress stalled for 15 mins. Refreshing inventory to check for external claims...", .warning),
            ("\(tag) Inventory refreshed: 530 claimed benefits, 18 in-progress drops", .info),
            ("\(tag) 1 drop(s) were claimed externally. Updating local state, resetting stall counter.", .info),
            ("\(tag) Inventory confirmed new progress during stall recovery. Keeping the current channel.", .info),
            ("\(tag) Progress genuinely stalled. Switching to failover streamer @someone for Rainbow Six Siege.", .info),
            ("\(tag) Progress genuinely stalled (no external claims detected). Switching channel.", .info),
            ("\(tag) Campaign \"R6S S2 2026 1\" stalled 3x with no progress and no external claims; skipping it for 30m and looking for other work.", .info),
            ("\(tag) Warning: Inventory refresh failed: timed out. Switching channel as fallback.", .warning)
        ]

        for (message, level) in window {
            let entry = EventEntry(message: message, level: level)
            XCTAssertEqual(
                primaryEventFilter(for: entry),
                .warnings,
                "anti-stall line filed away from its window: \(message)"
            )
        }
    }

    @MainActor
    func testAntiStallWindowSurvivesAFloodOfRoutineChatter() {
        let tag = MinerEngine.antiStallLogTag
        let start = Date()

        func categorised(_ message: String, level: EventLevel, at offset: TimeInterval) -> EventEntry {
            let base = EventEntry(timestamp: start.addingTimeInterval(offset), message: message, level: level)
            return base.withCategory(primaryEventFilter(for: base).rawValue)
        }

        // The window happens first, then a day of the chatter that used to bury it.
        var entries = [
            categorised("\(tag) Progress stalled for 15 mins. Refreshing inventory to check for external claims...", level: .warning, at: 0),
            categorised("\(tag) Inventory refreshed: 530 claimed benefits, 18 in-progress drops", level: .info, at: 1),
            categorised("\(tag) Progress genuinely stalled (no external claims detected). Switching channel.", level: .info, at: 2)
        ]
        for index in 0..<400 {
            let offset = TimeInterval(100 + index)
            entries.append(categorised("Selected channel someone for Rainbow Six Siege", level: .info, at: offset))
            entries.append(categorised("Started watching rainbow6", level: .info, at: offset))
            entries.append(categorised("Maintenance: Token validated/refreshed", level: .info, at: offset))
        }

        let retained = NavigationModel.applyRetention(to: entries, maxEntries: 50, perCategoryFloor: 5)
        let survivors = Set(retained.map(\.message))

        for line in entries.prefix(3).map(\.message) {
            XCTAssertTrue(survivors.contains(line), "retention evicted part of the stall window: \(line)")
        }
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

/// Twitch query compatibility is reported in the Activity Log rather than on the Settings
/// screen, so what the log says about a run — and where a run's hashes live — is the
/// contract worth pinning down.
@MainActor
final class TwitchCompatibilityActivityLogTests: XCTestCase {
    private func entry(
        _ message: String,
        level: EventLevel = .info,
        raw: String?
    ) -> EventEntry {
        EventEntry(message: message, level: level, rawMessage: raw)
    }

    func testACompatibilityRunStaysInOneCategoryPerLevel() {
        let started = entry(
            "Twitch query update started",
            raw: "[compatibility] update started · requested by: Settings → Advanced"
        )
        XCTAssertEqual(eventFilters(for: started), [.system])

        let failed = entry(
            "Safari extension unavailable — Twitch queries were not updated",
            level: .warning,
            raw: "[compatibility] safari extension unavailable · nothing was reported back"
        )
        XCTAssertEqual(eventFilters(for: failed), [.system, .warnings])
    }

    /// Every category in the default filter set, so a compatibility run is never invisible
    /// to someone who has not gone looking through the filter chips.
    func testCompatibilityEventsAreVisibleUnderTheDefaultFilters() {
        let defaults: Set<EventFilter> = [
            .audit, .drops, .errors, .heartbeats, .mining, .system, .updates, .warnings
        ]
        let event = entry(
            "No changes required — Twitch is using the queries SwiftMiner already has",
            raw: "[compatibility] no changes required · unchanged: Drops dashboard"
        )

        let page = activityLogPage(
            events: [event],
            selectedFilters: defaults,
            selectedMinerID: nil,
            searchText: "",
            minerNamesByID: [:],
            limit: 10
        )
        XCTAssertEqual(page.entries.map(\.message), [event.message])
    }

    func testTheWrittenMessageIsWhatTheRowShows() {
        let event = entry(
            "Twitch changed its drops dashboard query",
            raw: "[compatibility] query changed · Drops dashboard · SwiftMiner: \(String(repeating: "a", count: 64))"
        )
        // Not run through the raw-message parser: these messages are already written for
        // a person, and parsing them produced titles like "Twitch changed its drops".
        XCTAssertEqual(ActivityEventPresentation(event: event).title, event.message)
    }

    func testHashesTravelInTheEventsOwnDetailRatherThanSettings() {
        let appHash = String(repeating: "a", count: 64)
        let siteHash = String(repeating: "b", count: 64)
        let event = entry(
            "Twitch changed its drops dashboard query",
            raw: "[compatibility] query changed · Drops dashboard · SwiftMiner: \(appHash) · Twitch: \(siteHash)"
        )

        XCTAssertEqual(compatibilityDiagnostics(for: event), [
            "query changed",
            "Drops dashboard",
            "SwiftMiner: \(appHash)",
            "Twitch: \(siteHash)"
        ])
    }

    func testAnOrdinaryEventCarriesNoDiagnosticsAndStaysUnexpandable() {
        let event = entry("Started watching rainbow6", raw: "[Engine] Started watching rainbow6")
        XCTAssertTrue(compatibilityDiagnostics(for: event).isEmpty)
    }

    func testAnAdoptedReplacementIsReportedAsPlainGoodNews() {
        let outcome = TwitchQueryUpdateController.completionEntry(
            for: .init(adopted: [.viewerDropsDashboard], confirmed: [.inventory])
        )
        XCTAssertEqual(outcome.level, .info)
        XCTAssertTrue(outcome.message.contains("drops dashboard"))
        XCTAssertTrue(outcome.raw.contains("[compatibility] update completed"))
        XCTAssertTrue(outcome.raw.contains("adopted: Drops dashboard"))
        XCTAssertTrue(outcome.raw.contains("unchanged: Drops inventory"))
    }

    func testARunThatChangedNothingSaysSoWithoutRaisingAWarning() {
        let outcome = TwitchQueryUpdateController.completionEntry(
            for: .init(confirmed: GQLQuery.frequentlyRotated)
        )
        XCTAssertEqual(outcome.level, .info)
        XCTAssertEqual(
            outcome.message,
            "No changes required — Twitch is using the queries SwiftMiner already has"
        )
    }

    func testARefusedReplacementIsAWarningThatSaysWhatIsStillInUse() {
        let outcome = TwitchQueryUpdateController.completionEntry(
            for: .init(rejected: [.inventory])
        )
        XCTAssertEqual(outcome.level, .warning)
        XCTAssertTrue(outcome.message.contains("kept the one it had"))
    }

    func testASilentExtensionIsReportedAsTheSetupProblemItIs() {
        let outcome = TwitchQueryUpdateController.completionEntry(
            for: .init(unseen: GQLQuery.frequentlyRotated, failure: .extensionUnavailable)
        )
        XCTAssertEqual(outcome.level, .warning)
        XCTAssertTrue(outcome.message.contains("No response from the Safari extension"))
        XCTAssertTrue(outcome.raw.contains("Safari → Settings → Extensions"))
        // Both ways silence happens, because the app genuinely cannot tell them apart.
        XCTAssertTrue(outcome.raw.contains("switched off"))
        XCTAssertTrue(outcome.raw.contains("could not be handed back"))
    }

    func testSeveralQueriesReadAsASentenceNotAList() {
        XCTAssertEqual(
            TwitchQueryUpdateController.listed([.viewerDropsDashboard, .inventory]),
            "drops dashboard and drops inventory"
        )
        XCTAssertEqual(
            TwitchQueryUpdateController.listed([.inventory]),
            "drops inventory"
        )
    }
}

/// "Twitch didn't issue it" and "SwiftMiner had nowhere to ask" are different answers, and
/// the second one is the common one: `Available drops` only appears on a live channel page,
/// so an update run while no miner is watching a channel covers four queries, not five.
@MainActor
final class TwitchCompatibilitySkippedQueryTests: XCTestCase {
    func testAQueryWithNoPageToOpenIsNamedRatherThanLeftBlank() {
        let outcome = TwitchQueryUpdateController.completionEntry(
            for: .init(
                skipped: [.dropsHighlightServiceAvailableDrops],
                confirmed: [.viewerDropsDashboard, .inventory, .dropCampaignDetails, .directoryPageGame]
            )
        )

        XCTAssertEqual(outcome.level, .info)
        XCTAssertTrue(outcome.message.contains("available drops"))
        XCTAssertTrue(outcome.message.contains("was live to read it from"))
        XCTAssertTrue(outcome.raw.contains("no page to read them from"))
    }

    func testAFullRunSaysNothingAboutPagesItDidNotNeed() {
        let outcome = TwitchQueryUpdateController.completionEntry(
            for: .init(confirmed: GQLQuery.frequentlyRotated)
        )
        XCTAssertEqual(
            outcome.message,
            "No changes required — Twitch is using the queries SwiftMiner already has"
        )
        XCTAssertFalse(outcome.raw.contains("no page to read them from"))
    }

    /// A skipped query is not a missed one: it must not be reported as Twitch failing to
    /// issue something, because the request was never made.
    func testSkippedAndUnseenAreReportedSeparately() {
        let outcome = TwitchQueryUpdateController.completionEntry(
            for: .init(
                unseen: [.dropCampaignDetails],
                skipped: [.dropsHighlightServiceAvailableDrops],
                confirmed: [.viewerDropsDashboard]
            )
        )
        XCTAssertTrue(outcome.raw.contains("not issued by Twitch: Campaign details"))
        XCTAssertTrue(outcome.raw.contains("no page to read them from: Available drops"))
    }
}
