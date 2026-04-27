-- Migration 001: Action-Shaped Audit Model + Index Additions
-- Author: kimi
-- Context: Unblocks registerUser auditing, audit viewer, outbox monitor, user list
-- Phase: Phase 1 (schema lock)
-- SQLite compatible (recreate pattern for column changes)

-- ---------------------------------------------------------------------------
-- 1. admin_audit_log — recreate as action-typed with nullable targets
-- ---------------------------------------------------------------------------

-- SQLite: cannot DROP NOT NULL or ADD COLUMN with complex defaults on existing tables.
-- We migrate via rename → create → copy → drop.

ALTER TABLE admin_audit_log RENAME TO admin_audit_log_old;

CREATE TABLE admin_audit_log (
    id TEXT PRIMARY KEY,
    operator_id TEXT NOT NULL,
    action_type TEXT NOT NULL CHECK(action_type IN (
        'account.assigned',
        'account.reassigned',
        'user.registered',
        'user.activated',
        'user.suspended',
        'event.retry',
        'event.marked_sent',
        'event.marked_failed',
        'operator.login',
        'operator.logout'
    )),
    -- Generic nullable targets (at least one should usually be populated)
    target_twitch_id TEXT,
    target_discord_id TEXT,
    -- Assignment-specific context (populated for account.assigned / account.reassigned)
    from_discord_id TEXT,
    to_discord_id TEXT,
    -- Flexible metadata per action type
    metadata_json TEXT,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

-- Copy existing assignment-shaped rows into the new action-shaped table.
-- Legacy rows are treated as 'account.assigned' (or 'account.reassigned' if from_discord_id IS NOT NULL).
INSERT INTO admin_audit_log (
    id,
    operator_id,
    action_type,
    target_twitch_id,
    target_discord_id,
    from_discord_id,
    to_discord_id,
    metadata_json,
    created_at
)
SELECT
    id,
    operator_id,
    CASE WHEN from_discord_id IS NOT NULL THEN 'account.reassigned' ELSE 'account.assigned' END,
    twitch_id,           -- maps to target_twitch_id
    to_discord_id,       -- maps to target_discord_id (the new owner)
    from_discord_id,
    to_discord_id,
    metadata_json,
    created_at
FROM admin_audit_log_old;

DROP TABLE admin_audit_log_old;

-- Indices for viewer / query performance
CREATE INDEX IF NOT EXISTS idx_audit_created_at ON admin_audit_log(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_target_discord ON admin_audit_log(target_discord_id);
CREATE INDEX IF NOT EXISTS idx_audit_target_twitch ON admin_audit_log(target_twitch_id);
CREATE INDEX IF NOT EXISTS idx_audit_operator ON admin_audit_log(operator_id);
CREATE INDEX IF NOT EXISTS idx_audit_action_created ON admin_audit_log(action_type, created_at DESC);

-- ---------------------------------------------------------------------------
-- 2. event_outbox — add indices for monitor UI + poller performance
-- ---------------------------------------------------------------------------

CREATE INDEX IF NOT EXISTS idx_outbox_status_created ON event_outbox(status, created_at);
CREATE INDEX IF NOT EXISTS idx_outbox_event_type ON event_outbox(event_type);
CREATE INDEX IF NOT EXISTS idx_outbox_retry ON event_outbox(retry_count);

-- ---------------------------------------------------------------------------
-- 3. miner_users — add status index for user list filtering
-- ---------------------------------------------------------------------------

CREATE INDEX IF NOT EXISTS idx_miner_users_status ON miner_users(status);

-- ---------------------------------------------------------------------------
-- 4. twitch_accounts — add index for unowned-account queries (AdminOverviewView)
-- ---------------------------------------------------------------------------

CREATE INDEX IF NOT EXISTS idx_twitch_accounts_owner ON twitch_accounts(owner_discord_id);
