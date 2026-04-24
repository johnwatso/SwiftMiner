import Foundation
import SQLite3

/// Implementation of TokenStore using a local SQLite database (Phase 1).
/// Used by SwiftMinerService for persistent, multi-account storage.
public final class SQLiteTokenStore: TokenStore, Sendable {
    public let manager: SQLiteManager
    private let dateFormatter: DateFormatter

    public init(manager: SQLiteManager) {
        self.manager = manager
        self.dateFormatter = DateFormatter()
        self.dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        self.dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
    }

    public func save(account: Account) async throws {
        try await manager.execute { db in
            let sql = """
            INSERT INTO twitch_accounts (twitch_id, username, access_token, refresh_token, token_expiry, scopes, owner_discord_id, link_state)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(twitch_id) DO UPDATE SET
                username=excluded.username,
                access_token=excluded.access_token,
                refresh_token=excluded.refresh_token,
                token_expiry=excluded.token_expiry,
                scopes=excluded.scopes,
                owner_discord_id=COALESCE(excluded.owner_discord_id, owner_discord_id),
                link_state=CASE
                    WHEN excluded.owner_discord_id IS NOT NULL THEN 'linked'
                    ELSE link_state
                END;
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw self.dbError(db)
            }
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_text(statement, 1, account.id, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 2, account.username, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 3, account.accessToken, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 4, account.refreshToken, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 5, self.dateFormatter.string(from: account.tokenExpiry), -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 6, account.scopes.joined(separator: ","), -1, SQLITE_TRANSIENT)
            if let ownerDiscordId = account.ownerDiscordId {
                sqlite3_bind_text(statement, 7, ownerDiscordId, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(statement, 8, "linked", -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(statement, 7)
                sqlite3_bind_text(statement, 8, "unowned", -1, SQLITE_TRANSIENT)
            }

            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw self.dbError(db)
            }
        }
    }

    public func loadAllAccounts() async throws -> [Account] {
        return try await manager.query { db in
            let sql = "SELECT twitch_id, username, access_token, refresh_token, token_expiry, scopes, owner_discord_id FROM twitch_accounts;"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw self.dbError(db)
            }
            defer { sqlite3_finalize(statement) }

            var results: [Account] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                results.append(self.parseAccount(statement!))
            }
            return results
        }
    }

    public func loadAccount(twitchUserId: String) async throws -> Account? {
        return try await manager.query { db in
            let sql = "SELECT twitch_id, username, access_token, refresh_token, token_expiry, scopes, owner_discord_id FROM twitch_accounts WHERE twitch_id = ?;"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw self.dbError(db)
            }
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_text(statement, 1, twitchUserId, -1, SQLITE_TRANSIENT)

            if sqlite3_step(statement) == SQLITE_ROW {
                return self.parseAccount(statement!)
            }
            return nil
        }
    }

    public func updateTokenMaterial(twitchUserId: String, accessToken: String, refreshToken: String?, expiry: Date) async throws {
        try await manager.execute { db in
            let sql = """
            UPDATE twitch_accounts 
            SET access_token = ?, refresh_token = COALESCE(?, refresh_token), token_expiry = ? 
            WHERE twitch_id = ?;
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw self.dbError(db)
            }
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_text(statement, 1, accessToken, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 2, refreshToken, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 3, self.dateFormatter.string(from: expiry), -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 4, twitchUserId, -1, SQLITE_TRANSIENT)

            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw self.dbError(db)
            }
        }
    }

    public func deleteAccount(twitchUserId: String) async throws {
        try await manager.execute { db in
            let sql = "DELETE FROM twitch_accounts WHERE twitch_id = ?;"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw self.dbError(db)
            }
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_text(statement, 1, twitchUserId, -1, SQLITE_TRANSIENT)

            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw self.dbError(db)
            }
        }
    }

    private func parseAccount(_ statement: OpaquePointer) -> Account {
        let id = String(cString: sqlite3_column_text(statement, 0))
        let username = String(cString: sqlite3_column_text(statement, 1))
        let accessToken = String(cString: sqlite3_column_text(statement, 2))
        let refreshToken = sqlite3_column_text(statement, 3).map { String(cString: $0) }
        let expiryStr = String(cString: sqlite3_column_text(statement, 4))
        let scopesStr = String(cString: sqlite3_column_text(statement, 5))
        let ownerDiscordId = sqlite3_column_text(statement, 6).map { String(cString: $0) }
        
        let expiry = dateFormatter.date(from: expiryStr) ?? Date()
        let scopes = Self.parseScopes(scopesStr)

        return Account(
            id: id,
            username: username,
            ownerDiscordId: ownerDiscordId,
            accessToken: accessToken,
            refreshToken: refreshToken ?? "",
            tokenExpiry: expiry,
            scopes: scopes
        )
    }

    private static func parseScopes(_ value: String) -> [String] {
        value
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func dbError(_ db: OpaquePointer?) -> Error {
        let message = sqlite3_errmsg(db).map { String(cString: $0) } ?? "Unknown SQLite error"
        return NSError(domain: "SQLiteTokenStore", code: 3, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
