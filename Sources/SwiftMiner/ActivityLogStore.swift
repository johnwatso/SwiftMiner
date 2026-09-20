import Foundation
import SQLite3
import SwiftMinerCore

/// Persists Activity Log entries that need to survive app restarts.
actor ActivityLogStore {
    private let manager: SQLiteManager
    private var maxEntries: Int
    private var perCategoryFloor: Int
    private let archiveDirectoryURL: URL?
    private let archiveCalendar: Calendar
    private let archiveRetentionDays: Int
    private var archiveFileHandle: FileHandle?
    private var archiveFileURL: URL?
    private var lastArchivePruneDay: Date?
    /// Writes since the last prune. Pruning ran on every insert, which meant a
    /// DELETE with two subqueries per logged line at ~65 lines a minute.
    private var writesSincePrune = 0
    private static let writesBetweenPrunes = 250

    init(
        manager: SQLiteManager,
        maxEntries: Int = 5000,
        perCategoryFloor: Int = 500,
        archiveDirectoryURL: URL? = nil,
        archiveCalendar: Calendar = .current,
        archiveRetentionDays: Int = 7
    ) {
        self.manager = manager
        self.maxEntries = max(1, maxEntries)
        self.perCategoryFloor = max(0, perCategoryFloor)
        self.archiveDirectoryURL = archiveDirectoryURL
        self.archiveCalendar = archiveCalendar
        self.archiveRetentionDays = max(1, archiveRetentionDays)
    }

    /// Applies a new retention size. Shrinking prunes straight away so the change is
    /// visible immediately rather than at the next 250-write boundary.
    func setRetention(maxEntries newMax: Int, perCategoryFloor newFloor: Int) async {
        let clampedMax = max(1, newMax)
        let clampedFloor = max(0, newFloor)
        guard clampedMax != maxEntries || clampedFloor != perCategoryFloor else { return }
        let isShrinking = clampedMax < maxEntries || clampedFloor < perCategoryFloor
        maxEntries = clampedMax
        perCategoryFloor = clampedFloor
        if isShrinking {
            await prune()
        }
    }

    func save(_ entry: EventEntry) async {
        let shouldPrune: Bool
        writesSincePrune += 1
        if writesSincePrune >= Self.writesBetweenPrunes {
            writesSincePrune = 0
            shouldPrune = true
        } else {
            shouldPrune = false
        }

        do {
            try await manager.execute { db in
                let sql = """
                INSERT OR REPLACE INTO activity_log_entries
                    (id, timestamp, message, level, miner_id, raw_message, category)
                VALUES (?, ?, ?, ?, ?, ?, ?);
                """
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                    throw activityLogSQLiteError(db, operation: "prepare activity-log insert")
                }
                defer { sqlite3_finalize(stmt) }

                sqlite3_bind_text(stmt, 1, entry.id.uuidString, -1, SQLITE_TRANSIENT_ACTIVITY_LOG)
                sqlite3_bind_double(stmt, 2, entry.timestamp.timeIntervalSince1970)
                sqlite3_bind_text(stmt, 3, entry.message, -1, SQLITE_TRANSIENT_ACTIVITY_LOG)
                sqlite3_bind_text(stmt, 4, entry.level.rawValue, -1, SQLITE_TRANSIENT_ACTIVITY_LOG)
                if let minerId = entry.minerId {
                    sqlite3_bind_text(stmt, 5, minerId, -1, SQLITE_TRANSIENT_ACTIVITY_LOG)
                } else {
                    sqlite3_bind_null(stmt, 5)
                }
                if let rawMessage = entry.rawMessage {
                    sqlite3_bind_text(stmt, 6, rawMessage, -1, SQLITE_TRANSIENT_ACTIVITY_LOG)
                } else {
                    sqlite3_bind_null(stmt, 6)
                }
                if let category = entry.category {
                    sqlite3_bind_text(stmt, 7, category, -1, SQLITE_TRANSIENT_ACTIVITY_LOG)
                } else {
                    sqlite3_bind_null(stmt, 7)
                }
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw activityLogSQLiteError(db, operation: "insert activity-log entry")
                }
            }
        } catch {
            // Best effort: logging must never block the UI or web request path.
            Logger.storage.error("Failed to save activity-log entry: \(error.localizedDescription)")
        }

        do {
            try appendToDailyArchive(entry)
        } catch {
            // SQLite remains the UI store if the plain-file archive is temporarily
            // unavailable. One failed diagnostic write must never stop mining.
            Logger.storage.error("Failed to append daily activity log: \(error.localizedDescription)")
        }

        if shouldPrune {
            await prune()
        }
    }

    /// Keeps the newest `maxEntries` overall plus the newest `perCategoryFloor` of each
    /// category. Recency alone deleted every audit row and every warning inside an hour,
    /// because routine cycle chatter is the overwhelming majority of what gets logged.
    func prune() async {
        let retainedOverall = maxEntries
        let retainedPerCategory = perCategoryFloor
        do {
            try await manager.execute { db in
                let sql = """
                DELETE FROM activity_log_entries
                WHERE id NOT IN (
                    SELECT id
                    FROM activity_log_entries
                    ORDER BY timestamp DESC
                    LIMIT ?1
                )
                AND id NOT IN (
                    SELECT id FROM (
                        SELECT id, ROW_NUMBER() OVER (
                            PARTITION BY COALESCE(category, 'system')
                            ORDER BY timestamp DESC
                        ) AS rank_in_category
                        FROM activity_log_entries
                    )
                    WHERE rank_in_category <= ?2
                );
                """
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                    throw activityLogSQLiteError(db, operation: "prepare activity-log prune")
                }
                defer { sqlite3_finalize(stmt) }
                sqlite3_bind_int(stmt, 1, Int32(retainedOverall))
                sqlite3_bind_int(stmt, 2, Int32(retainedPerCategory))
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw activityLogSQLiteError(db, operation: "prune activity-log entries")
                }
            }
        } catch {
            // Best effort.
            Logger.storage.error("Failed to prune activity-log entries: \(error.localizedDescription)")
        }
    }

    /// Returns the newest `limit` entries plus the newest `perCategoryFloor` of each
    /// category. Loading purely by recency would leave the protected audit and warning
    /// rows sitting on disk but missing from the UI, which is the bug this store exists
    /// to avoid — selecting one filter has to show that filter's history.
    func loadEntries(limit: Int) async -> [EventEntry] {
        let retainedPerCategory = perCategoryFloor
        do {
            return try await manager.query { db in
                let sql = """
                SELECT id, timestamp, message, level, miner_id, raw_message, category
                FROM activity_log_entries
                WHERE id IN (
                    SELECT id
                    FROM activity_log_entries
                    ORDER BY timestamp DESC
                    LIMIT ?1
                )
                OR id IN (
                    SELECT id FROM (
                        SELECT id, ROW_NUMBER() OVER (
                            PARTITION BY COALESCE(category, 'system')
                            ORDER BY timestamp DESC
                        ) AS rank_in_category
                        FROM activity_log_entries
                    )
                    WHERE rank_in_category <= ?2
                )
                ORDER BY timestamp DESC;
                """
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                    throw activityLogSQLiteError(db, operation: "prepare activity-log query")
                }
                defer { sqlite3_finalize(stmt) }
                sqlite3_bind_int(stmt, 1, Int32(max(limit, 0)))
                sqlite3_bind_int(stmt, 2, Int32(retainedPerCategory))

                var entries: [EventEntry] = []
                var stepResult = sqlite3_step(stmt)
                while stepResult == SQLITE_ROW {
                    guard let idText = sqlite3_column_text(stmt, 0),
                          let messageText = sqlite3_column_text(stmt, 2),
                          let levelText = sqlite3_column_text(stmt, 3)
                    else {
                        stepResult = sqlite3_step(stmt)
                        continue
                    }

                    let id = UUID(uuidString: String(cString: idText)) ?? UUID()
                    let timestamp = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1))
                    let level = EventLevel(rawValue: String(cString: levelText)) ?? .info
                    let minerId = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
                    let rawMessage = sqlite3_column_text(stmt, 5).map { String(cString: $0) }
                    let category = sqlite3_column_text(stmt, 6).map { String(cString: $0) }
                    entries.append(EventEntry(
                        id: id,
                        timestamp: timestamp,
                        message: String(cString: messageText),
                        level: level,
                        minerId: minerId,
                        rawMessage: rawMessage,
                        category: category
                    ))
                    stepResult = sqlite3_step(stmt)
                }
                guard stepResult == SQLITE_DONE else {
                    throw activityLogSQLiteError(db, operation: "read activity-log entries")
                }
                return entries
            }
        } catch {
            Logger.storage.error("Failed to load activity-log entries: \(error.localizedDescription)")
            return []
        }
    }

    /// Loads the retained daily files for diagnostic export. These files are the durable,
    /// seven-day timeline; the SQLite rows above remain a bounded working set for the UI.
    func loadArchivedEntries(now: Date = Date()) -> [EventEntry] {
        guard let archiveDirectoryURL else { return [] }

        do {
            try archiveFileHandle?.synchronize()
        } catch {
            Logger.storage.warning("Could not flush the current daily activity log before export: \(error.localizedDescription)")
        }

        let decoder = Self.archiveDecoder()
        var entries: [EventEntry] = []
        var corruptLineCount = 0

        for fileURL in archiveFileURLs(now: now, directory: archiveDirectoryURL) {
            guard let data = try? Data(contentsOf: fileURL) else { continue }
            for line in data.split(separator: 0x0A) where !line.isEmpty {
                do {
                    let record = try decoder.decode(ArchivedEvent.self, from: Data(line))
                    entries.append(record.eventEntry)
                } catch {
                    corruptLineCount += 1
                }
            }
        }

        if corruptLineCount > 0 {
            Logger.storage.warning("Skipped \(corruptLineCount) unreadable line(s) in daily activity logs")
        }
        return entries.sorted { $0.timestamp < $1.timestamp }
    }

    func clear() async {
        do {
            try await manager.execute { db in
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, "DELETE FROM activity_log_entries;", -1, &stmt, nil) == SQLITE_OK else {
                    throw activityLogSQLiteError(db, operation: "prepare activity-log clear")
                }
                defer { sqlite3_finalize(stmt) }
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw activityLogSQLiteError(db, operation: "clear activity-log entries")
                }
            }
        } catch {
            // Best effort.
            Logger.storage.error("Failed to clear activity-log entries: \(error.localizedDescription)")
        }

        do {
            try closeArchiveFile()
            guard let archiveDirectoryURL,
                  FileManager.default.fileExists(atPath: archiveDirectoryURL.path)
            else { return }
            for fileURL in try FileManager.default.contentsOfDirectory(
                at: archiveDirectoryURL,
                includingPropertiesForKeys: nil
            ) where Self.isArchiveFile(fileURL) {
                try FileManager.default.removeItem(at: fileURL)
            }
        } catch {
            Logger.storage.error("Failed to clear daily activity logs: \(error.localizedDescription)")
        }
    }

    private func appendToDailyArchive(_ entry: EventEntry) throws {
        guard let archiveDirectoryURL else { return }
        try FileManager.default.createDirectory(
            at: archiveDirectoryURL,
            withIntermediateDirectories: true
        )

        let targetURL = archiveDirectoryURL.appendingPathComponent(
            Self.archiveFilename(for: entry.timestamp, calendar: archiveCalendar)
        )
        if archiveFileURL != targetURL {
            try closeArchiveFile()
            if !FileManager.default.fileExists(atPath: targetURL.path) {
                guard FileManager.default.createFile(atPath: targetURL.path, contents: nil) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            archiveFileHandle = try FileHandle(forWritingTo: targetURL)
            try archiveFileHandle?.seekToEnd()
            archiveFileURL = targetURL
        }

        var encoded = try Self.archiveEncoder().encode(ArchivedEvent(entry))
        encoded.append(0x0A)
        try archiveFileHandle?.write(contentsOf: encoded)

        // Use the current wall day for retention rather than the entry timestamp. Saves can
        // complete out of order across SQLite's await at midnight; an older entry must never
        // prune the new day's file that another save has just created.
        let pruneReference = max(Date(), entry.timestamp)
        let day = archiveCalendar.startOfDay(for: pruneReference)
        if lastArchivePruneDay != day {
            try pruneDailyArchives(now: pruneReference, directory: archiveDirectoryURL)
            lastArchivePruneDay = day
        }
    }

    private func pruneDailyArchives(now: Date, directory: URL) throws {
        let retainedNames = Set(archiveFileURLs(now: now, directory: directory).map(\.lastPathComponent))
        for fileURL in try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) where Self.isArchiveFile(fileURL) && !retainedNames.contains(fileURL.lastPathComponent) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }

    private func archiveFileURLs(now: Date, directory: URL) -> [URL] {
        let today = archiveCalendar.startOfDay(for: now)
        return (0..<archiveRetentionDays).reversed().compactMap { daysAgo in
            guard let day = archiveCalendar.date(byAdding: .day, value: -daysAgo, to: today) else {
                return nil
            }
            return directory.appendingPathComponent(
                Self.archiveFilename(for: day, calendar: archiveCalendar)
            )
        }
    }

    private func closeArchiveFile() throws {
        try archiveFileHandle?.close()
        archiveFileHandle = nil
        archiveFileURL = nil
    }

    private static func archiveFilename(for date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return "SwiftMiner-activity-\(formatter.string(from: date)).log"
    }

    private static func isArchiveFile(_ url: URL) -> Bool {
        url.lastPathComponent.hasPrefix("SwiftMiner-activity-") && url.pathExtension == "log"
    }

    private static func archiveEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }

    private static func archiveDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}

private struct ArchivedEvent: Codable {
    let schemaVersion: Int
    let id: UUID
    let timestamp: Date
    let message: String
    let level: EventLevel
    let minerId: String?
    let rawMessage: String?
    let category: String?

    init(_ entry: EventEntry) {
        schemaVersion = 1
        id = entry.id
        timestamp = entry.timestamp
        message = entry.message
        level = entry.level
        minerId = entry.minerId
        rawMessage = entry.rawMessage
        category = entry.category
    }

    var eventEntry: EventEntry {
        EventEntry(
            id: id,
            timestamp: timestamp,
            message: message,
            level: level,
            minerId: minerId,
            rawMessage: rawMessage,
            category: category
        )
    }
}

private let SQLITE_TRANSIENT_ACTIVITY_LOG = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private func activityLogSQLiteError(_ db: OpaquePointer?, operation: String) -> NSError {
    let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "database unavailable"
    return NSError(
        domain: "ActivityLogStore",
        code: Int(sqlite3_errcode(db)),
        userInfo: [NSLocalizedDescriptionKey: "SQLite could not \(operation): \(message)"]
    )
}
