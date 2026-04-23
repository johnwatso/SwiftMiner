import Foundation
import SQLite3

/// Manages the local SQLite database for SwiftMinerService (Phase 1).
/// Implements the 9-table schema from v1.3 spec.
public actor SQLiteManager {
    private var db: OpaquePointer?
    private let dbPath: URL

    public init(databaseURL: URL) {
        self.dbPath = databaseURL
    }

    public func open() throws {
        if sqlite3_open(dbPath.path, &db) != SQLITE_OK {
            let error = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "SQLiteManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to open DB: \(error)"])
        }
        try createSchema()
    }

    public func close() {
        sqlite3_close(db)
        db = nil
    }

    private func createSchema() throws {
        let schema = """
        -- 1. miner_users
        CREATE TABLE IF NOT EXISTS miner_users (
            discord_id TEXT PRIMARY KEY,
            status TEXT NOT NULL CHECK(status IN ('registered', 'active', 'suspended')),
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP
        );

        -- 2. twitch_accounts
        CREATE TABLE IF NOT EXISTS twitch_accounts (
            twitch_id TEXT PRIMARY KEY,
            owner_discord_id TEXT,
            username TEXT NOT NULL,
            access_token TEXT NOT NULL,
            refresh_token TEXT,
            token_expiry DATETIME NOT NULL,
            scopes TEXT,
            link_state TEXT NOT NULL CHECK(link_state IN ('linked', 'expired', 'unowned')),
            FOREIGN KEY(owner_discord_id) REFERENCES miner_users(discord_id) ON DELETE SET NULL
        );

        -- 3. user_game_preferences
        CREATE TABLE IF NOT EXISTS user_game_preferences (
            discord_id TEXT,
            game_id TEXT,
            state TEXT NOT NULL CHECK(state IN ('preferred', 'excluded', 'neutral')),
            PRIMARY KEY(discord_id, game_id),
            FOREIGN KEY(discord_id) REFERENCES miner_users(discord_id) ON DELETE CASCADE
        );

        -- 4. reward_ledger
        CREATE TABLE IF NOT EXISTS reward_ledger (
            twitch_id TEXT,
            benefit_id TEXT PRIMARY KEY,
            reward_name TEXT,
            claimed_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY(twitch_id) REFERENCES twitch_accounts(twitch_id) ON DELETE CASCADE
        );

        -- 5. oauth_link_sessions
        CREATE TABLE IF NOT EXISTS oauth_link_sessions (
            id TEXT PRIMARY KEY,
            discord_id TEXT NOT NULL,
            state_nonce TEXT NOT NULL,
            expires_at DATETIME NOT NULL,
            FOREIGN KEY(discord_id) REFERENCES miner_users(discord_id) ON DELETE CASCADE
        );

        -- 6. event_outbox (Renamed from webhook_deliveries)
        CREATE TABLE IF NOT EXISTS event_outbox (
            id TEXT PRIMARY KEY,
            event_type TEXT NOT NULL,
            payload TEXT NOT NULL,
            status TEXT NOT NULL, -- 'pending', 'sent', 'failed'
            retry_count INTEGER DEFAULT 0,
            last_attempt DATETIME,
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP
        );

        -- 7. user_issues
        CREATE TABLE IF NOT EXISTS user_issues (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            discord_id TEXT NOT NULL,
            twitch_id TEXT NOT NULL,
            issue_type TEXT NOT NULL,
            message TEXT,
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY(discord_id) REFERENCES miner_users(discord_id) ON DELETE CASCADE
        );

        -- 8. opportunity_blocked_events
        CREATE TABLE IF NOT EXISTS opportunity_blocked_events (
            dedupe_key TEXT PRIMARY KEY, -- (user, campaign, window, reason)
            discord_id TEXT NOT NULL,
            last_notified DATETIME DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY(discord_id) REFERENCES miner_users(discord_id) ON DELETE CASCADE
        );

        -- 9. progress_event_state
        CREATE TABLE IF NOT EXISTS progress_event_state (
            campaign_id TEXT,
            twitch_id TEXT,
            last_milestone INTEGER, -- 25, 50, 75, 100
            PRIMARY KEY(campaign_id, twitch_id)
        );

        -- 10. admin_audit_log (Locked spec requirement)
        CREATE TABLE IF NOT EXISTS admin_audit_log (
            id TEXT PRIMARY KEY,
            operator_id TEXT NOT NULL,
            twitch_id TEXT NOT NULL,
            from_discord_id TEXT,
            to_discord_id TEXT NOT NULL,
            metadata_json TEXT,
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP
        );
        """
        try execute(schema)
    }

    public func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<Int8>?
        if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "Unknown error"
            sqlite3_free(error)
            throw NSError(domain: "SQLiteManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "SQL error: \(message)"])
        }
    }

    /// Perform a transaction on the DB.
    public func transaction<T: Sendable>(_ block: @Sendable (OpaquePointer) throws -> T) async throws -> T {
        guard let db else { throw NSError(domain: "SQLiteManager", code: 3, userInfo: [NSLocalizedDescriptionKey: "DB not open"]) }
        
        try execute("BEGIN TRANSACTION;")
        do {
            let result = try block(db)
            try execute("COMMIT;")
            return result
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    /// Perform a write operation on the raw DB pointer.
    public func execute<T: Sendable>(_ block: @Sendable (OpaquePointer) throws -> T) async throws -> T {
        guard let db else { throw NSError(domain: "SQLiteManager", code: 3, userInfo: [NSLocalizedDescriptionKey: "DB not open"]) }
        return try block(db)
    }

    /// Perform a read operation on the raw DB pointer.
    public func query<T: Sendable>(_ block: @Sendable (OpaquePointer) throws -> T) async throws -> T {
        guard let db else { throw NSError(domain: "SQLiteManager", code: 4, userInfo: [NSLocalizedDescriptionKey: "DB not open"]) }
        return try block(db)
    }
    
    // Internal helper for raw pointer access (for TokenStore)
    internal var dbPointer: OpaquePointer? { db }
}
