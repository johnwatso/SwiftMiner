import Foundation
import SQLite3
import SwiftMinerCore

/// Persists Activity Log entries that need to survive app restarts.
actor ActivityLogStore {
    private let manager: SQLiteManager
    private let maxEntries: Int

    init(manager: SQLiteManager, maxEntries: Int = 5000) {
        self.manager = manager
        self.maxEntries = max(1, maxEntries)
    }

    func save(_ entry: EventEntry) async {
        do {
            try await manager.execute { db in
                let sql = """
                INSERT OR REPLACE INTO activity_log_entries
                    (id, timestamp, message, level, miner_id, raw_message)
                VALUES (?, ?, ?, ?, ?, ?);
                """
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
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
                _ = sqlite3_step(stmt)

                // Keep the on-disk timeline bounded to the same size as the UI.
                let pruneSQL = """
                DELETE FROM activity_log_entries
                WHERE id NOT IN (
                    SELECT id
                    FROM activity_log_entries
                    ORDER BY timestamp DESC
                    LIMIT ?
                );
                """
                var pruneStatement: OpaquePointer?
                guard sqlite3_prepare_v2(db, pruneSQL, -1, &pruneStatement, nil) == SQLITE_OK else { return }
                defer { sqlite3_finalize(pruneStatement) }
                sqlite3_bind_int(pruneStatement, 1, Int32(self.maxEntries))
                _ = sqlite3_step(pruneStatement)
            }
        } catch {
            // Best effort: logging must never block the UI or web request path.
        }
    }

    func loadEntries(limit: Int) async -> [EventEntry] {
        do {
            return try await manager.query { db in
                let sql = """
                SELECT id, timestamp, message, level, miner_id, raw_message
                FROM activity_log_entries
                ORDER BY timestamp DESC
                LIMIT ?;
                """
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
                defer { sqlite3_finalize(stmt) }
                sqlite3_bind_int(stmt, 1, Int32(max(limit, 0)))

                var entries: [EventEntry] = []
                while sqlite3_step(stmt) == SQLITE_ROW {
                    guard let idText = sqlite3_column_text(stmt, 0),
                          let messageText = sqlite3_column_text(stmt, 2),
                          let levelText = sqlite3_column_text(stmt, 3)
                    else { continue }

                    let id = UUID(uuidString: String(cString: idText)) ?? UUID()
                    let timestamp = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1))
                    let level = EventLevel(rawValue: String(cString: levelText)) ?? .info
                    let minerId = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
                    let rawMessage = sqlite3_column_text(stmt, 5).map { String(cString: $0) }
                    entries.append(EventEntry(
                        id: id,
                        timestamp: timestamp,
                        message: String(cString: messageText),
                        level: level,
                        minerId: minerId,
                        rawMessage: rawMessage
                    ))
                }
                return entries
            }
        } catch {
            return []
        }
    }

    func clear() async {
        do {
            try await manager.execute { db in
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, "DELETE FROM activity_log_entries;", -1, &stmt, nil) == SQLITE_OK else { return }
                defer { sqlite3_finalize(stmt) }
                _ = sqlite3_step(stmt)
            }
        } catch {
            // Best effort.
        }
    }
}

private let SQLITE_TRANSIENT_ACTIVITY_LOG = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
