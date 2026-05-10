-- Adds payload + debug-flag columns to dm_log so the Discord tab can:
--   1. Show debug previews separately from production sends (DEBUG builds).
--   2. Re-send the most recent DM verbatim from the contextual menu.

ALTER TABLE dm_log ADD COLUMN payload_json TEXT;
ALTER TABLE dm_log ADD COLUMN debug INTEGER NOT NULL DEFAULT 0;

INSERT OR IGNORE INTO _schema_migrations (version) VALUES (8);
