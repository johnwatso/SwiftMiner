-- Tracks user-facing SwiftBot DM progression without storing presentation data.
-- Debug DM previews must not mutate these flags.

ALTER TABLE miner_users
ADD COLUMN has_received_welcome_message INTEGER NOT NULL DEFAULT 0;

ALTER TABLE miner_users
ADD COLUMN has_completed_initial_dm_flow INTEGER NOT NULL DEFAULT 0;

INSERT OR IGNORE INTO _schema_migrations (version) VALUES (6);
