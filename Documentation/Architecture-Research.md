# SwiftTwitchMiner — Architecture Research

> Reverse-engineered from TwitchDropsMiner (Python reference implementation)
> Date: 2026-03-17

---

## 1. Miner Lifecycle (State Machine)

The miner runs a continuous async loop cycling through these states:

```
IDLE → INVENTORY_FETCH → GAMES_UPDATE → CHANNELS_CLEANUP
     → CHANNELS_FETCH → CHANNEL_SWITCH → (watching) → IDLE
```

1. **Authenticate** — OAuth device-code flow or cookie restore
2. **Fetch Inventory** — GQL `Inventory` + `Campaigns` queries
3. **Determine Games** — filter eligible, linked, active campaigns
4. **Fetch Channels** — GQL `GameDirectory` per game (live streams)
5. **Select Channel** — priority sort (ACL-based > viewer count)
6. **Watch Loop** — POST Spade beacon every ~59 s
7. **Poll Progress** — WebSocket events + GQL `CurrentDrop` fallback
8. **Claim** — GQL `ClaimDrop` mutation when progress reaches 100 %
9. **Repeat** — move to next drop / campaign

---

## 2. Authentication

### Device Code Flow (preferred)
```
POST https://id.twitch.tv/oauth2/device
  body: client_id, scopes

→ { device_code, user_code, verification_uri, interval }

Poll POST https://id.twitch.tv/oauth2/token
  body: client_id, device_code, grant_type=urn:ietf:params:oauth:grant-type:device_code

→ { access_token, refresh_token }
```

### Session Validation
```
GET https://id.twitch.tv/oauth2/validate
  header: Authorization: OAuth <access_token>

→ { user_id, login, expires_in }
```

### Required Headers (every GQL / API request)
| Header | Value |
|--------|-------|
| `Client-Id` | Twitch web client ID |
| `X-Device-Id` | 16-char hex (from cookies or generated) |
| `Client-Session-Id` | 16-char hex nonce (per session) |
| `Authorization` | `OAuth <access_token>` |

### Persistence
- Store `access_token`, `user_id`, `device_id` in **Keychain**
- Restore session on launch; re-authenticate only if token invalid

---

## 3. GraphQL API

**Endpoint:** `https://gql.twitch.tv/gql`

All queries use **persisted queries** (sha256 hash, not inline GQL):

```json
{
  "operationName": "OperationName",
  "extensions": {
    "persistedQuery": { "version": 1, "sha256Hash": "<hash>" }
  },
  "variables": { ... }
}
```

### Key Operations

| Operation | Purpose |
|-----------|---------|
| `Inventory` | In-progress drop campaigns for current user |
| `Campaigns` | All active/upcoming drop campaigns |
| `CampaignDetails` | Full details for one campaign |
| `GetStreamInfo` | Live stream metadata for a channel |
| `AvailableDrops` | Drops available on a specific channel |
| `CurrentDrop` | User's current drop progress |
| `ClaimDrop` | Claim a completed drop reward |
| `PlaybackAccessToken` | HLS token (needed for Spade URL extraction) |
| `GameDirectory` | Live channels currently streaming a game |

### Rate Limiting
- Target: ≤ 5 requests / second
- Retry on: `"service error"`, `"service timeout"`, `"service unavailable"`, `"PersistedQueryNotFound"`
- Backoff: exponential, max 60 s

---

## 4. Drop Campaign Model

```
DropsCampaign
  id, name
  game: Game (name, slug)
  starts_at, ends_at: Date
  linked: Bool          ← user account linked to game's service
  allowed_channels: [Channel]   ← ACL whitelist (may be empty)
  timed_drops: [TimedDrop]

TimedDrop
  id, name
  required_minutes: Int
  current_minutes: Int  ← real + locally-estimated
  claim_id: String      ← "{user_id}#{campaign_id}#{drop_id}"
  is_claimed: Bool
  benefits: [Benefit]   ← badge / emote / entitlement
  precondition_drops: [TimedDrop]
```

### Eligibility Rules
- Campaign must be `ACTIVE`
- User account must be `linked` to game service (unless badges/emotes only)
- All `precondition_drops` must be claimed first
- Drop `required_minutes > 0`

---

## 5. Stream Watching Simulation

### Spade Beacon (primary method)
```
POST <spade_url>          ← dynamic URL extracted from Twitch channel page HTML
Content-Type: application/x-www-form-urlencoded

data=<base64(JSON)>

JSON payload:
{
  "event": "minute-watched",
  "properties": {
    "broadcast_id": <stream_id>,
    "channel_id": <channel_id>,
    "channel": "<login>",
    "user_id": <user_id>,
    "player": "site",
    "location": "channel",
    "logged_in": true,
    "live": true,
    "hidden": false,
    "muted": false
  }
}
```

- **Interval:** every **59 seconds**
- **Expected response:** `204 No Content`

### Spade URL Extraction
1. Fetch `https://www.twitch.tv/<channel_login>` page
2. Find link to `settings.js` bundle
3. Fetch `settings.js`, extract `spade_url` or `beacon_url`
4. Cache per channel

---

## 6. Drop Progress Polling

Three sources, in priority order:

### Priority 1 — WebSocket Events
- Topic: `user-drop-events.<user_id>`
- Events:
  - `"drop-progress"` → `{ current_progress_min, required_progress_min }`
  - `"drop-claim"` → `{ drop_instance_id }` (triggers claim)

### Priority 2 — GQL `CurrentDrop`
- Poll when WebSocket data is stale (> 60 s since last update)
- Returns `currentMinutesWatched` and `dropID`

### Priority 3 — Local Estimation
- Increment local counter every 59 s (max 15 extra minutes)
- If max reached without server confirmation → force channel switch

---

## 7. Drop Claiming

```
1. Receive drop_instance_id (from WebSocket "drop-claim" event)
2. GQL ClaimDrop { dropInstanceID: drop_instance_id }
3. Expect status: "ELIGIBLE_FOR_ALL" or "DROP_INSTANCE_ALREADY_CLAIMED"
4. Poll CurrentDrop up to 8× (every 2 s) to confirm progress advanced
5. Move to next drop in campaign
```

### Claim ID Format
`<user_id>#<campaign_id>#<drop_id>` — can be generated locally as fallback.

---

## 8. WebSocket (PubSub)

**URL:** `wss://pubsub-edge.twitch.tv/v1`

### Limits
- Up to **8 concurrent connections**
- Up to **50 topics per connection**
- Max **342 total topics** (8×50 − 2 base topics)

### Topic Types
| Topic ID | Purpose |
|----------|---------|
| `user-drop-events.<uid>` | Drop progress & claim events |
| `onsite-notifications.<uid>` | Drop notifications |
| `video-playback-by-id.<channel_id>` | Stream up/down/viewcount |
| `broadcast-settings-update.<channel_id>` | Title/game changes |

### Message Protocol
```json
// Subscribe
{ "type": "LISTEN", "nonce": "<uuid>", "data": { "topics": [...], "auth_token": "<token>" } }

// Heartbeat (every 3 min)
{ "type": "PING" }

// Server response
{ "type": "PONG" }
{ "type": "MESSAGE", "data": { "topic": "...", "message": "<json_string>" } }
{ "type": "RECONNECT" }
```

- PONG must arrive within **10 seconds** of PING, else reconnect
- Exponential backoff on reconnect, max 3 minutes

---

## 9. Channel Selection

Priority order:
1. User-selected channel (GUI override)
2. ACL-based channels that are online (campaign whitelist)
3. Channels sorted by: game priority rank → viewer count (desc)

Switch triggers:
- Higher-priority game becomes available
- ACL channel comes online
- Current channel goes offline / loses drops / changes game

---

## 10. Key Timing Constants

| Constant | Value | Purpose |
|----------|-------|---------|
| `WATCH_INTERVAL` | 59 s | Spade beacon frequency |
| `PING_INTERVAL` | 3 min | WebSocket heartbeat |
| `PING_TIMEOUT` | 10 s | PONG wait window |
| `ONLINE_DELAY` | 120 s | Grace period after `stream-up` event |
| `MAX_EXTRA_MINUTES` | 15 min | Local estimation cap |
| `CLAIM_POLL_ATTEMPTS` | 8 | Post-claim progress verification |
| `CLAIM_POLL_INTERVAL` | 2 s | Between claim verification polls |
| `GQL_RATE_LIMIT` | 5 req/s | GraphQL rate limit |
| `GQL_MAX_BACKOFF` | 60 s | Max retry backoff |
| `WS_MAX_BACKOFF` | 3 min | Max WebSocket reconnect backoff |

---

## 11. Swift Implementation Notes

### Concurrency
- `MinerEngine` → Swift `actor` (isolates mutable state)
- Watch loop → `Task` with `AsyncStream` or `for await` on `AsyncSequence`
- WebSocket → `URLSessionWebSocketTask`
- Timers → `AsyncStream` wrapping `Timer` or `clock.sleep`

### Networking
- All HTTP → `URLSession` with `async/await`
- GraphQL → `URLRequest` with JSON body, `Codable` responses
- Cookies → `HTTPCookieStorage.shared`

### Persistence
- OAuth tokens → **Keychain** (`Security` framework)
- Settings → `UserDefaults` or `Codable` + `FileManager`
- Spade URL cache → in-memory `Dictionary` (re-fetch each launch)

### Key Dependencies (no third-party required)
- `Foundation` — URLSession, JSONDecoder, Codable
- `Security` — Keychain
- `CryptoKit` — any needed hashing
- `SwiftUI` — dashboard layer (phase 2)

---

## 12. Proposed File Structure

```
Sources/SwiftTwitchMiner/
├── Engine/
│   ├── MinerEngine.swift          ← actor, lifecycle state machine
│   └── MinerState.swift           ← State enum
├── Services/
│   ├── TwitchAuthService.swift    ← device-code OAuth, token storage
│   ├── TwitchAPIClient.swift      ← URLSession wrapper, GQL requests
│   ├── DropsService.swift         ← campaign fetch, eligibility
│   ├── WatchSessionManager.swift  ← Spade beacon loop
│   ├── ClaimService.swift         ← claim mutation + verification
│   └── PubSubClient.swift         ← WebSocket PubSub
├── Models/
│   ├── Account.swift
│   ├── Campaign.swift
│   ├── Drop.swift
│   ├── Channel.swift
│   ├── Stream.swift
│   └── Game.swift
└── Utils/
    ├── KeychainHelper.swift
    ├── RateLimiter.swift
    └── Logger.swift
```
