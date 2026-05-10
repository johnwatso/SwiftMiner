-- Records DMs sent from SwiftMiner to a Discord user. Lets the Discord tab
-- show a per-account "what messages have I sent?" history. Debug previews
-- are excluded by callers; this table only stores production sends.

CREATE TABLE IF NOT EXISTS dm_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    discord_id TEXT NOT NULL,
    message_type TEXT NOT NULL,
    sent_at REAL NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_dm_log_discord_recent
    ON dm_log(discord_id, sent_at DESC);

INSERT OR IGNORE INTO _schema_migrations (version) VALUES (7);
