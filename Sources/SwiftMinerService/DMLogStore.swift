import Foundation
import SQLite3
import SwiftMinerCore

/// Records DMs sent from SwiftMiner to a Discord user, so the Discord tab can
/// show a per-account "what messages have I sent?" history and offer re-send.
public actor DMLogStore {
    public struct Entry: Sendable, Equatable {
        public let messageType: String
        public let sentAt: Date
        public let isDebug: Bool

        public init(messageType: String, sentAt: Date, isDebug: Bool) {
            self.messageType = messageType
            self.sentAt = sentAt
            self.isDebug = isDebug
        }
    }

    private let manager: SQLiteManager

    public init(manager: SQLiteManager) {
        self.manager = manager
    }

    public func record(discordUserId: String, request: SwiftBotDMRequest, at date: Date = Date()) async {
        let payloadJSON = (try? JSONEncoder().encode(request))
            .flatMap { String(data: $0, encoding: .utf8) }
        do {
            try await manager.execute { db in
                let sql = """
                INSERT INTO dm_log (discord_id, message_type, sent_at, payload_json, debug)
                VALUES (?, ?, ?, ?, ?);
                """
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
                defer { sqlite3_finalize(stmt) }
                sqlite3_bind_text(stmt, 1, discordUserId, -1, SQLITE_TRANSIENT_DM_LOG)
                sqlite3_bind_text(stmt, 2, request.messageType.rawValue, -1, SQLITE_TRANSIENT_DM_LOG)
                sqlite3_bind_double(stmt, 3, date.timeIntervalSince1970)
                if let payloadJSON {
                    sqlite3_bind_text(stmt, 4, payloadJSON, -1, SQLITE_TRANSIENT_DM_LOG)
                } else {
                    sqlite3_bind_null(stmt, 4)
                }
                sqlite3_bind_int(stmt, 5, request.debug ? 1 : 0)
                _ = sqlite3_step(stmt)
            }
        } catch {
            // Best effort — do not block the send path.
        }
    }

    /// Returns the most recent entries, newest first. Pass `includeDebug: true`
    /// in DEBUG builds to see preview sends alongside production ones.
    public func recentEntries(
        forDiscordId discordUserId: String,
        limit: Int = 50,
        includeDebug: Bool = false
    ) async -> [Entry] {
        do {
            return try await manager.query { db in
                let sql: String
                if includeDebug {
                    sql = """
                    SELECT message_type, sent_at, debug FROM dm_log
                    WHERE discord_id = ?
                    ORDER BY sent_at DESC
                    LIMIT ?;
                    """
                } else {
                    sql = """
                    SELECT message_type, sent_at, debug FROM dm_log
                    WHERE discord_id = ? AND debug = 0
                    ORDER BY sent_at DESC
                    LIMIT ?;
                    """
                }
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
                defer { sqlite3_finalize(stmt) }
                sqlite3_bind_text(stmt, 1, discordUserId, -1, SQLITE_TRANSIENT_DM_LOG)
                sqlite3_bind_int(stmt, 2, Int32(limit))

                var entries: [Entry] = []
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let type = String(cString: sqlite3_column_text(stmt, 0))
                    let ts = sqlite3_column_double(stmt, 1)
                    let isDebug = sqlite3_column_int(stmt, 2) != 0
                    entries.append(Entry(
                        messageType: type,
                        sentAt: Date(timeIntervalSince1970: ts),
                        isDebug: isDebug
                    ))
                }
                return entries
            }
        } catch {
            return []
        }
    }

    public struct Summary: Sendable, Equatable {
        public let count: Int
        public let lastSentAt: Date?
    }

    /// One query that returns total production-DM count and last-sent timestamp
    /// for every Discord ID in `discordIds`. IDs with no entries are omitted.
    public func summaries(forDiscordIds discordIds: [String]) async -> [String: Summary] {
        let unique = Array(Set(discordIds))
        guard !unique.isEmpty else { return [:] }
        do {
            return try await manager.query { db in
                let placeholders = Array(repeating: "?", count: unique.count).joined(separator: ",")
                let sql = """
                SELECT discord_id, COUNT(*), MAX(sent_at) FROM dm_log
                WHERE debug = 0 AND discord_id IN (\(placeholders))
                GROUP BY discord_id;
                """
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
                defer { sqlite3_finalize(stmt) }
                for (idx, id) in unique.enumerated() {
                    sqlite3_bind_text(stmt, Int32(idx + 1), id, -1, SQLITE_TRANSIENT_DM_LOG)
                }
                var result: [String: Summary] = [:]
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let id = String(cString: sqlite3_column_text(stmt, 0))
                    let count = Int(sqlite3_column_int(stmt, 1))
                    let ts = sqlite3_column_double(stmt, 2)
                    result[id] = Summary(count: count, lastSentAt: ts > 0 ? Date(timeIntervalSince1970: ts) : nil)
                }
                return result
            }
        } catch {
            return [:]
        }
    }

    /// Returns the most recently sent *production* DM payload for re-sending.
    /// Debug previews are excluded so a "Re-send last message" action never
    /// accidentally replays a test embed.
    public func mostRecentProductionRequest(forDiscordId discordUserId: String) async -> SwiftBotDMRequest? {
        do {
            return try await manager.query { db in
                let sql = """
                SELECT payload_json FROM dm_log
                WHERE discord_id = ? AND debug = 0 AND payload_json IS NOT NULL
                ORDER BY sent_at DESC
                LIMIT 1;
                """
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
                defer { sqlite3_finalize(stmt) }
                sqlite3_bind_text(stmt, 1, discordUserId, -1, SQLITE_TRANSIENT_DM_LOG)
                guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
                guard let cString = sqlite3_column_text(stmt, 0) else { return nil }
                let json = String(cString: cString)
                guard let data = json.data(using: .utf8) else { return nil }
                return try? JSONDecoder().decode(SwiftBotDMRequest.self, from: data)
            }
        } catch {
            return nil
        }
    }
}

private let SQLITE_TRANSIENT_DM_LOG = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
