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
        try applyMigrations()
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
        CREATE INDEX IF NOT EXISTS idx_miner_users_status ON miner_users(status);

        -- 2. twitch_accounts
        CREATE TABLE IF NOT EXISTS twitch_accounts (
            twitch_id TEXT PRIMARY KEY,
            owner_discord_id TEXT,
            username TEXT NOT NULL,
            nickname TEXT,
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

        -- 6. event_outbox
        CREATE TABLE IF NOT EXISTS event_outbox (
            id TEXT PRIMARY KEY,
            event_type TEXT NOT NULL,
            payload TEXT NOT NULL,
            idempotency_key TEXT,
            status TEXT NOT NULL, -- 'pending', 'delivering', 'sent', 'failed_retryable', 'failed_terminal'
            retry_count INTEGER DEFAULT 0,
            last_attempt DATETIME,
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP
        );
        CREATE INDEX IF NOT EXISTS idx_outbox_status_created ON event_outbox(status, created_at);
        CREATE INDEX IF NOT EXISTS idx_outbox_event_type ON event_outbox(event_type);
        CREATE INDEX IF NOT EXISTS idx_outbox_retry ON event_outbox(retry_count);
        CREATE INDEX IF NOT EXISTS idx_twitch_accounts_owner ON twitch_accounts(owner_discord_id);

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

        -- 10. admin_audit_log
        CREATE TABLE IF NOT EXISTS admin_audit_log (
            id TEXT PRIMARY KEY,
            action_type TEXT NOT NULL DEFAULT 'account_assigned',
            operator_id TEXT NOT NULL,
            twitch_id TEXT,
            from_discord_id TEXT,
            to_discord_id TEXT,
            metadata_json TEXT,
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP
        );

        -- 11. user_campaign_decisions
        CREATE TABLE IF NOT EXISTS user_campaign_decisions (
            discord_id TEXT,
            campaign_id TEXT,
            decision TEXT NOT NULL CHECK(decision IN ('ignored', 'prioritised')),
            scope TEXT NOT NULL CHECK(scope IN ('temporary', 'permanent')),
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY(discord_id, campaign_id),
            FOREIGN KEY(discord_id) REFERENCES miner_users(discord_id) ON DELETE CASCADE
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
    
    // MARK: - Migrations

    private func applyMigrations() throws {
        try execute("""
        CREATE TABLE IF NOT EXISTS _schema_migrations (
            version INTEGER PRIMARY KEY,
            applied_at DATETIME DEFAULT CURRENT_TIMESTAMP
        );
        """)

        if !columnExists("action_type", in: "admin_audit_log") {
            try migration1_recreateAdminAuditLog()
        }
        try createAdminAuditIndexes()

        if !isMigrationApplied(1) {
            try execute("INSERT OR IGNORE INTO _schema_migrations (version) VALUES (1);")
        }

        if !isMigrationApplied(2) {
            if !columnExists("idempotency_key", in: "event_outbox") {
                try execute("ALTER TABLE event_outbox ADD COLUMN idempotency_key TEXT;")
            }
            try execute("""
            CREATE INDEX IF NOT EXISTS idx_outbox_status_created ON event_outbox(status, created_at);
            CREATE INDEX IF NOT EXISTS idx_outbox_event_type ON event_outbox(event_type);
            CREATE INDEX IF NOT EXISTS idx_outbox_retry ON event_outbox(retry_count);
            CREATE INDEX IF NOT EXISTS idx_twitch_accounts_owner ON twitch_accounts(owner_discord_id);
            """)
            try execute("INSERT OR IGNORE INTO _schema_migrations (version) VALUES (2);")
        }

        if !isMigrationApplied(3) {
            try execute("""
            CREATE TABLE IF NOT EXISTS user_campaign_decisions (
                discord_id TEXT,
                campaign_id TEXT,
                decision TEXT NOT NULL CHECK(decision IN ('ignored', 'prioritised')),
                scope TEXT NOT NULL CHECK(scope IN ('temporary', 'permanent')),
                created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY(discord_id, campaign_id),
                FOREIGN KEY(discord_id) REFERENCES miner_users(discord_id) ON DELETE CASCADE
            );
            """)
            try execute("INSERT OR IGNORE INTO _schema_migrations (version) VALUES (3);")
        }

        if !isMigrationApplied(4) {
            try execute("""
            DELETE FROM event_outbox
            WHERE idempotency_key IS NOT NULL
              AND rowid NOT IN (
                SELECT MIN(rowid)
                FROM event_outbox
                WHERE idempotency_key IS NOT NULL
                GROUP BY idempotency_key
              );
            CREATE UNIQUE INDEX IF NOT EXISTS idx_outbox_idempotency_key_unique
                ON event_outbox(idempotency_key)
                WHERE idempotency_key IS NOT NULL;
            """)
            try execute("INSERT OR IGNORE INTO _schema_migrations (version) VALUES (4);")
        }

        if !isMigrationApplied(5) {
            if !columnExists("nickname", in: "twitch_accounts") {
                try execute("ALTER TABLE twitch_accounts ADD COLUMN nickname TEXT;")
            }
            try execute("INSERT OR IGNORE INTO _schema_migrations (version) VALUES (5);")
        }
    }

    private func isMigrationApplied(_ version: Int) -> Bool {
        guard let db else { return false }
        let sql = "SELECT COUNT(*) FROM _schema_migrations WHERE version = \(version);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return false }
        return sqlite3_column_int(stmt, 0) > 0
    }

    private func columnExists(_ column: String, in table: String) -> Bool {
        guard let db else { return false }
        let sql = "SELECT COUNT(*) FROM pragma_table_info('\(table)') WHERE name = '\(column)';"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return false }
        return sqlite3_column_int(stmt, 0) > 0
    }

    private func migration1_recreateAdminAuditLog() throws {
        try execute("DROP TABLE IF EXISTS admin_audit_log_new;")
        try execute("""
        CREATE TABLE admin_audit_log_new (
            id TEXT PRIMARY KEY,
            action_type TEXT NOT NULL DEFAULT 'account_assigned',
            operator_id TEXT NOT NULL,
            twitch_id TEXT,
            from_discord_id TEXT,
            to_discord_id TEXT,
            metadata_json TEXT,
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP
        );
        """)
        try execute("""
        INSERT INTO admin_audit_log_new
            (id, action_type, operator_id, twitch_id, from_discord_id, to_discord_id, metadata_json, created_at)
        SELECT id, 'account_assigned', operator_id, twitch_id, from_discord_id, to_discord_id, metadata_json, created_at
        FROM admin_audit_log;
        """)
        try execute("DROP TABLE admin_audit_log;")
        try execute("ALTER TABLE admin_audit_log_new RENAME TO admin_audit_log;")
        try execute("""
        CREATE INDEX IF NOT EXISTS idx_audit_operator ON admin_audit_log(operator_id);
        CREATE INDEX IF NOT EXISTS idx_audit_twitch_id ON admin_audit_log(twitch_id);
        CREATE INDEX IF NOT EXISTS idx_audit_to_discord ON admin_audit_log(to_discord_id);
        CREATE INDEX IF NOT EXISTS idx_audit_action_type ON admin_audit_log(action_type);
        CREATE INDEX IF NOT EXISTS idx_audit_created_at ON admin_audit_log(created_at);
        """)
    }

    private func createAdminAuditIndexes() throws {
        try execute("""
        CREATE INDEX IF NOT EXISTS idx_audit_operator ON admin_audit_log(operator_id);
        CREATE INDEX IF NOT EXISTS idx_audit_twitch_id ON admin_audit_log(twitch_id);
        CREATE INDEX IF NOT EXISTS idx_audit_to_discord ON admin_audit_log(to_discord_id);
        CREATE INDEX IF NOT EXISTS idx_audit_action_type ON admin_audit_log(action_type);
        CREATE INDEX IF NOT EXISTS idx_audit_created_at ON admin_audit_log(created_at);
        """)
    }

    // Internal helper for raw pointer access (for TokenStore)
    internal var dbPointer: OpaquePointer? { db }
}
