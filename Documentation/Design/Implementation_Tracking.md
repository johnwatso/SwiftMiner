# Implementation Tracking

**Design doc:** `SwiftMiner_SwiftBot_Integration.md` (v1.0-locked)  
**Tracker owner:** @kimi  
**Status:** Phase 2/3 — COMPLETE. Phase 4 integration verification in progress.

---

## Implementation Phase Map

### Phase 1: Backend Foundation — Backend/API + @kimi

| Design Section | Expected Code Changes | Status | Notes |
|----------------|----------------------|--------|-------|
| 2.7 Projection Schema | `Sources/SwiftMinerService/Models/DiscordUserProjection.swift` (new) | ✅ Complete | Projection model struct |
| 2.7 `GET /discord/users/:id` | `Sources/SwiftMinerService/DiscordAPIRoutes.swift` + `DiscordProjectionBuilder.swift` | ✅ Complete | Returns full projection; DB-only heuristics with optional `ProjectionStateProvider` for live engine data |
| 3.1 Activation persistence | `Sources/SwiftMinerCore/Persistence/SQLiteManager.swift` — schema already has `oauth_link_sessions` | ✅ Exists | In-memory session store + DB audit rows; full device-flow integration pending |
| 3.2 `user_campaign_decisions` | `Sources/SwiftMinerCore/Persistence/SQLiteManager.swift` — Migration 3 | ✅ Complete | Table + `ON CONFLICT` upsert in `DiscordAPIRoutes.swift` |
| 2.6 Identity mapping | `Sources/SwiftMinerService/AdminLinkingService.swift` — `OperatorIdentity` enum | ✅ Complete | Replaces `operatorId: String` |
| 2.6 `registerUser` audit | `Sources/SwiftMinerService/AdminLinkingService.swift` — add audit write + outbox event | ✅ Complete | Blocks on schema migration |
| 2.1 API auth | `Authorization: Bot {key}` middleware | ✅ Complete | Enforced in `HTTPAPIServer` for all non-health routes |
| 2.1 HTTP Server | `Sources/SwiftMinerService/HTTPAPIServer.swift` (new) | ✅ Complete | `Network.framework` based; routes, request parsing, JSON responses |
| 5. Readiness — WAL mode | `SQLiteManager` — enable WAL if not already | ⏳ Not started | Concurrent reads |

### Phase 2: Event/Webhook Layer — @codex + Backend/API

| Design Section | Expected Code Changes | Status | Notes |
|----------------|----------------------|--------|-------|
| 2.2 `user.stateChanged` | `EventEmitterService.swift` (new) or added to `AdminLinkingService` | ✅ Complete | Emitted on projection state change |
| 2.2 `user.actionRequired` | Same as above | ✅ Complete | Emitted when issues appear |
| 2.2 `user.dropClaimed` | Same as above | ✅ Complete | Emitted on claim success |
| 2.2 `user.opportunityAvailable` | Same as above | ✅ Complete | Emitted on new upNext |
| 2.3 Webhook delivery | `WebhookDeliveryService.swift` (new) | ✅ Complete | HMAC signature, retry logic (as `EventOutboxService.swift`) |
| 2.3 Event outbox poller | `Sources/SwiftMinerService/main.swift` or new service | ✅ Complete | Reads `event_outbox`, delivers to webhook URL |
| 4. Idempotency keys | Key generation logic in event emitter | ✅ Complete | Stable across retries |

### Phase 3: Bot Integration — @gemini

| Design Section | Expected Code Changes | Status | Notes |
|----------------|----------------------|--------|-------|
| 2.8 Always-fetch-first | SwiftBot HTTP client — `GET /discord/users/:id` before every render | ✅ Complete | `SwiftMinerClient.swift` implemented |
| 2.8 State-to-render mapping | SwiftBot message templates per `projection.state` | ✅ Complete | `notConfigured`, `active`, `idle`, `blocked` |
| 2.8 Issue action buttons | SwiftBot Discord UI components | ✅ Complete | `link_account`, `ignore_campaign`, `ignore_game` |
| 2.8 Event DM rendering | SwiftBot webhook handler → fetch projection → render DM | ✅ Complete | All 4 event types in `AppModel+AdminWeb.swift` |
| 2.4 Activation UX | SwiftBot activation flow — show code card, poll session | ✅ Complete | Device code flow + background polling |
| 2.4 Cancel activation | `SwiftMinerClient.cancelActivation` | ✅ Complete | DELETE endpoint support |
| Model parity | `SwiftMinerModels.swift` `campaignId` field | ✅ Complete | Matches backend projection schema |

### Phase 4: Verification — @kimi + @gemini

| Check | Method | Status |
|-------|--------|--------|
| API contract matches design | Diff endpoint signatures against section 2.1 + 2.7 | ✅ Complete |
| Event payloads match design | Diff emitted events against section 2.2 | ⏳ Pending |
| Webhook delivery matches design | Test HMAC, retry, idempotency against section 2.3 | ⏳ Pending |
| Projection mapping matches design | Verify internal → projection state rules from section 2.7 | ✅ Complete |
| SwiftBot rendering matches design | Verify always-fetch-first, state mapping from section 2.8 | ✅ Complete (@gemini) |
| Campaign actions durable | Verify ignore/prioritise persists to DB | ✅ Complete |
| No contract drift | Compare code against v1.0-locked doc | 🔄 In Progress |

---

## Known Blockers / Dependencies

| Blocker | Blocks | Owner | Status |
|---------|--------|-------|--------|
| Schema migration (001) | `registerUser` audit, projection tables | Backend/API | ✅ Resolved |
| `OperatorIdentity` type | All audit writes, API auth | Backend/API | ✅ Resolved |
| HTTP API server | SwiftBot client integration testing | @kimi | ✅ Resolved |
| Projection service | Event emitter (needs state to diff), API endpoint | @kimi | ✅ Resolved |
| Webhook URL settings | Webhook delivery service | Backend/API or admin config | ✅ Exists in Settings.swift |
| Migration 3 (`user_campaign_decisions`) | Durable campaign actions | @gemini | ✅ Resolved |
| SwiftBot build | End-to-end functional testing | @gemini | 🔄 SwiftLint sandbox env issue; Swift code compiles |

---

## Design Doc Version Control

| Version | Date | Change | Author |
|---------|------|--------|--------|
| v0.1 | 2026-04-24 | Initial skeleton | @kimi |
| v0.2 | 2026-04-24 | API + events + webhooks integrated | Backend/API, @codex, @kimi |
| v0.3 | 2026-04-24 | Phase 2 complete, cross-check open | @kimi |
| v0.4 | 2026-04-24 | Projection refinement | Backend/API, @codex, @kimi |
| **v1.0-locked** | 2026-04-24 | Design locked | @kimi |

---

*Last updated: 2026-04-24T12:25Z by @kimi*
