# Pre-Phase 3 Readiness Notes

**Author:** @kimi  
**Date:** 2026-04-24  
**Status:** Phase 1 schema contract locked, pending @John approval  
**Scope:** Gap analysis between current admin/audit implementation and Phase 3 API readiness

---

## 1. Legacy Audit Caveat

**Decision:** All pre-migration `admin_audit_log` rows will be backfilled with `action_type = 'account_assigned'` during the Migration 001 cutover. This is intentional and minimal.

**Implication:** Rows that historically represented reassignments will not be distinguishable as `account_reassigned` after backfill. The audit viewer should treat any row without a specific `action_type` distinction (or all pre-migration rows) as **legacy**.

**Viewer guidance for @codex:**
- Render pre-migration rows with a "legacy" badge or group them separately.
- Do not attempt to parse `metadata_json` to retroactively classify legacy rows.
- The `created_at` timestamp remains accurate; only the `action_type` granularity is lost.

---

## 2. Locked Schema Contract (Phase 1)

### `admin_audit_log`

| Column | Type | Null? | Notes |
|--------|------|-------|-------|
| `id` | TEXT PRIMARY KEY | No | UUID |
| `action_type` | TEXT | No | DEFAULT `'account_assigned'` |
| `operator_id` | TEXT | No | `"local_admin"` or `"bot:<keyId>"` (Phase 3) |
| `twitch_id` | TEXT | Yes | NULL for `user_registered` actions |
| `from_discord_id` | TEXT | Yes | Previous owner (reassignment only) |
| `to_discord_id` | TEXT | Yes | Target Discord user |
| `metadata_json` | TEXT | Yes | Action-specific payload |
| `created_at` | DATETIME | No | DEFAULT CURRENT_TIMESTAMP |

**Supported `action_type` values (snake_case — internal audit field, distinct from dotted event types):**
- `account_assigned`
- `account_reassigned`
- `user_registered`
- `user_activated`
- `user_suspended`
- `event_retry`
- `event_marked_sent`
- `event_marked_failed`
- `operator_login`
- `operator_logout`

### Indices Added

| Table | Index | Columns | Status |
|-------|-------|---------|--------|
| `admin_audit_log` | `idx_audit_operator` | `operator_id` | ✅ Landed (migration 1) |
| `admin_audit_log` | `idx_audit_twitch_id` | `twitch_id` | ✅ Landed (migration 1) |
| `admin_audit_log` | `idx_audit_to_discord` | `to_discord_id` | ✅ Landed (migration 1) |
| `admin_audit_log` | `idx_audit_action_type` | `action_type` | ✅ Landed (migration 1) |
| `admin_audit_log` | `idx_audit_created_at` | `created_at` | ✅ Landed (migration 1) |
| `event_outbox` | `idx_outbox_status_created` | `status, created_at` | Phase 2 (@codex) |
| `event_outbox` | `idx_outbox_event_type` | `event_type` | Phase 2 (@codex) |
| `event_outbox` | `idx_outbox_retry` | `retry_count` | Phase 2 (@codex) |
| `miner_users` | `idx_miner_users_status` | `status` | ✅ Already in createSchema |
| `twitch_accounts` | `idx_twitch_accounts_owner` | `owner_discord_id` | Phase 2 (@codex) |

**Note:** `idx_miner_users_status` is already live in `SQLiteManager.swift` (landed by @gemini).

---

## 3. Phase 3 API Blockers

### 🔴 Hard Blockers (must resolve before Phase 3 API ships)

| # | Item | Owner | Status |
|---|------|-------|--------|
| 1 | `operatorId` hardcoded as `"local_admin"` in UI sheets | @claude | ✅ Done |
| 2 | No `OperatorIdentity` type in service layer | @claude | ✅ Done |
| 3 | `registerUser` unaudited + no outbox event | @claude | ✅ Done |
| 4 | `RestSwiftBotConnectionService` has no auth headers / API key / JWT | @claude | Phase 3 design |
| 5 | `admin_audit_log.operator_id` is plain TEXT with no FK / operator table | @claude | Phase 1 (deferred to string value) |

### 🟡 Soft Blockers (should resolve before Phase 3, but not fatal)

| # | Item | Owner | Status |
|---|------|-------|--------|
| 6 | TOCTOU reassignment path has zero test coverage | @claude | Phase 2 |
| 7 | Idempotency on `assignAccount` is untested | @claude | Phase 2 |
| 8 | Concurrent `miner_users` creation race (UNIQUE constraint is only guard) | @claude | Phase 2 |
| 9 | Admin panel hidden when `swiftBotEnabled == false` (unlinked accounts accumulate silently) | UX decision | Pending @John |

### 🟢 Non-Blockers (nice-to-have)

| # | Item | Owner |
|---|------|-------|
| 10 | Audit log viewer UI | @codex | Phase 3 |
| 11 | Event outbox monitor UI | @codex | Phase 3 |
| 12 | Registered users management view | @gemini | Phase 3 (already live) |
| 13 | Bulk account assignment operations | Future |

---

## 4. Operator Identity Contract (Proposed)

**Phase 1:** `OperatorIdentity.stringValue` → `"local_admin"`  
**Phase 3:** `OperatorIdentity.stringValue` → `"bot:<apiKeyId>"` or `"user:<discordId>"`

The `admin_audit_log.operator_id` column accepts any TEXT value. There is no FK constraint to an `operators` table in Phase 1. A proper operators reference table can be introduced in Phase 3 when real bot identities and OAuth sessions exist.

**Migration path:** When an `operators` table is added later, backfill `operator_id` values by parsing the existing string format, then add the FK constraint via a future migration.

---

## 5. Test Coverage Gaps

| Area | Current Tests | Needed | Owner |
|------|---------------|--------|-------|
| `assignAccount` happy path | ? | Confirm exists | @claude |
| `assignAccount` idempotency | None | Same-pair double call → single audit row | @claude |
| `assignAccount` TOCTOU reassignment | None | Owner changes between UI read and transaction | @claude |
| `registerUser` audit write | None | Verify row + outbox event | @claude |
| `getUnownedAccounts` | ? | Confirm exists | @claude |
| Outbox event emission | ? | Confirm `user.linked` payload shape | @claude |

---

## 6. Files Touched by Migration 001

- `Sources/SwiftMinerCore/Persistence/SQLiteManager.swift` — schema + indices
- `Sources/SwiftMinerService/AdminLinkingService.swift` — `registerUser` audit + outbox
- `Sources/SwiftMinerService/Models/AdminLinkingTypes.swift` — `OperatorIdentity` type
- `Sources/SwiftMiner/AdminView.swift` — `.localAdmin` wiring
- `Sources/SwiftMiner/AdminOverviewView.swift` — `.localAdmin` wiring

---

## 7. Sign-Off

- [x] @claude — schema contract approved (Phase 1 complete, build green)
- [ ] @codex — audit viewer query shape approved
- [ ] @gemini — user list index dependency satisfied
- [ ] @John — Phase 1 implementation approved

---

*Ready for Phase 1 implementation pending @John approval.*
