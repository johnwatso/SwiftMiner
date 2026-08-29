import Foundation
import SQLite3
import SwiftMinerCore

/// Persists Activity Log entries that need to survive app restarts.
actor ActivityLogStore {
    private let manager: SQLiteManager
    private var maxEntries: Int
    private var perCategoryFloor: Int
    /// Writes since the last prune. Pruning ran on every insert, which meant a
    /// DELETE with two subqueries per logged line at ~65 lines a minute.
    private var writesSincePrune = 0
    private static let writesBetweenPrunes = 250

    init(manager: SQLiteManager, maxEntries: Int = 5000, perCategoryFloor: Int = 500) {
        self.manager = manager
        self.maxEntries = max(1, maxEntries)
        self.perCategoryFloor = max(0, perCategoryFloor)
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
