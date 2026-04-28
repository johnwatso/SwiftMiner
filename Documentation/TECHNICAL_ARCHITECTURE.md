# SwiftMinerCore — Technical Architecture

> **Current as of:** March 2026
> **Build status:** ✅ Clean
> **Architecture:** Fully native Swift macOS — no Python, no subprocesses

---

## 1. Project Overview

**SwiftMinerCore** is a fully native macOS SwiftUI application that automates Twitch drop mining across multiple accounts simultaneously. It has no external dependencies on Python, worker subprocesses, or third-party runtimes — everything runs in-process in Swift.

The app is a **multi-account supervisor dashboard**. It:

- Manages N independent miner instances (one per Twitch account)
- Authenticates each account via Twitch OAuth device-code flow
- Discovers active drop campaigns via Twitch GraphQL
- Simulates live viewing via Spade analytics beacons (59-second interval)
- Receives real-time drop progress/claim events via Twitch PubSub (WebSocket)
- Automatically claims completed drops
- Presents a native macOS Tahoe-style `NavigationSplitView` dashboard

---

## 2. Current Architecture

### Layer Overview

```
SwiftMiner  (macOS .app target — SwiftUI layer)
    └── depends on ↓
SwiftMinerCore     (static library — engine layer)
```

### Engine Layer: `SwiftMinerCore`

#### `MinerEngine` (actor)
The core per-account orchestrator. One instance per Twitch account. Owns all services for that account. Exposes `start()`, `stop()`, `authenticate()`, `claimAllDrops()`, `getCurrentProgress()`.

#### `MinerManager` (@MainActor @Observable)
Supervisor for all `MinerEngine` instances. Holds:
- `miners: [ManagedMiner]` — observable array of per-account state structs
- `engines: [String: MinerEngine]` — private actor references keyed by miner ID

Exposes `addAccount()`, `removeAccount()`, `startMiner()`, `stopMiner()`, `startAll()`, `stopAll()`, `claimAllDropsAllMiners()`, `getAggregateProgress()`.

#### `TwitchAuthService` (actor)
Handles OAuth device-code flow and token lifecycle. Saves tokens to Keychain. Refreshes expired tokens and notifies subscribers via `onTokenRefresh` callback.

#### `TwitchAPIClient` (actor)
Central HTTP/GraphQL client. All Twitch API calls go through here. Features:
- Rate limiting via `RateLimiter` (token bucket, 5 req/s)
- Persisted query support with `PersistedQueryNotFound` auto-detection
- All SHA-256 hashes centralised in `GQLHashes` enum
- `traceGQL()` debug trace on every call

#### `DropsService` (actor)
Business logic for drops. Calls `TwitchAPIClient` to fetch active campaigns, fetch inventory, get claimable drops, and find live channels for a game.

#### `WatchSessionManager` (actor)
Manages the watch simulation loop. Calls `SpadeBeaconService` every 59 seconds. Tracks total watch time. Requires user ID (set via `setUserId()`).

#### `SpadeBeaconService` (actor)
Sends `minute-watched` Spade analytics beacons to Twitch. Extracts the dynamic spade URL from the channel page HTML (cached per channel, falls back to `spade.twitch.tv/track`). Sends `data=<base64 JSON>` POST with correct `User-Agent` and `Referer` headers.

#### `PubSubClient` (actor)
WebSocket client for `wss://pubsub-edge.twitch.tv/v1`. Features:
- PING every 3 minutes / PONG timeout 10 seconds
- Exponential backoff reconnect (1s base, 60s max)
- LISTEN topics authenticated with the current OAuth token
- Topics: `user-drop-events.<userId>`, `video-playback-by-id.<channelId>`

#### `DropEventsService` (actor)
Interprets raw PubSub messages. Parses `drop-progress`, `drop-claim`, stream-up/down/viewcount/commercial events. Fires typed Swift callbacks. Connects `PubSubClient` → `MinerEngine`.

#### `ClaimService` (actor)
Validates drop readiness and calls `TwitchAPIClient.claimDrop()`. Returns `ClaimResult`. Supports single-drop and bulk-claim modes.

#### `RateLimiter` (actor)
Sliding-window token bucket. Default: 5 requests per 1 second. `wait()` blocks async callers until a slot is available.

#### `DebugTrace` (actor)
Optional categorised trace logger. Categories: `[GraphQL]`, `[PubSub]`, `[Spade]`, `[Claim]`, `[Auth]`. Output forwarded to the same `onLogMessage` callback as engine logs when debug mode is enabled.

---

## 3. Concurrency Model

The project uses **Swift 6 strict concurrency** throughout.

| Mechanism | Usage |
|---|---|
| `actor` | Every service: `TwitchAuthService`, `TwitchAPIClient`, `DropsService`, `WatchSessionManager`, `SpadeBeaconService`, `PubSubClient`, `DropEventsService`, `ClaimService`, `RateLimiter`, `DebugTrace`, `MinerEngine` |
| `@MainActor` | `MinerManager`, `NavigationModel`, `MinerLoginService` — SwiftUI-facing classes |
| `@Sendable` | All callbacks crossing actor boundaries |
| `async/await` | Throughout — no `DispatchQueue`, no legacy callbacks except at actor boundaries |
| `Task { [weak self] in }` | Fire-and-forget operations inside actors |

Multiple miners run simultaneously because each `MinerEngine` is an independent Swift `actor` — they execute their async work concurrently without sharing mutable state. `MinerManager` coordinates them from `@MainActor`.

The main mining loop in each engine (`runMiningLoop()`) is a `while isRunning` loop with `Task.sleep` for the campaign-check interval (5 minutes). The inner watch sub-loop sleeps 60 seconds between progress checks.

---

## 4. Twitch Protocol Handling

### GraphQL — Persisted Queries

All queries use Twitch's persisted query format:

```json
{
  "extensions": {
    "persistedQuery": { "version": 1, "sha256Hash": "<hash>" }
  },
  "variables": { ... }
}
```

SHA-256 hashes live in `GQLHashes.swift`. On `PersistedQueryNotFound` error, `TwitchAPIClient` throws `TwitchMinerError.apiError`.

Key operations:

| Operation | Purpose |
|---|---|
| `ViewerDropsDashboard` | Fetch active campaigns + inventory |
| `DropsHighlightServiceAvailableDrops` | Claimable drops |
| `VideoPlayerStreamInfoOverlayChannel` | Fetch broadcast ID for a live stream |
| `ClaimDropRewards` | Claim a completed drop |

### Spade Beacon — Watch Simulation

Every 59 seconds, `SpadeBeaconService.sendBeacon()` POSTs:

```
data=<base64([{"event":"minute-watched","properties":{...}}])>
```

to the channel's dynamic spade URL (or `spade.twitch.tv/track` as fallback). The POST includes a browser `User-Agent` and `Referer: https://www.twitch.tv/<channel>`.

### PubSub WebSocket

`PubSubClient` connects to `wss://pubsub-edge.twitch.tv/v1`. After connection:

1. Sends `LISTEN` for `user-drop-events.<userId>` and `video-playback-by-id.<channelId>`
2. Sends PING every 3 minutes; expects PONG within 10 seconds
3. On PONG timeout or `RECONNECT` message: exponential backoff reconnect, re-subscribe all topics
4. Access token updated on refresh via `updateAccessToken()`

### Drop Progress & Claiming

**Real-time path (PubSub):**
- `drop-progress` → `DropEventsService` → `MinerEngine.handleDropProgress()` → `DropsService.getOverallProgress()` → UI update
- `drop-claim` → `DropEventsService` → `MinerEngine.handleDropClaim()` → `TwitchAPIClient.claimDrop(dropInstanceId:)`

**Polling fallback:**
- `claimReadyDrops()` runs at engine start and every 60 seconds in the watch loop
- Calls `DropsService.getClaimableDrops()` → `ClaimService.claimDrop()` for each ready drop

---

## 5. Data Flow — Miner Lifecycle

```
MinerManager.startMiner(minerId:)
  └── MinerEngine.start()
        │
        ├─ 1. TwitchAuthService.loadSavedAccount()
        │      loads token from Keychain; throws if missing/expired
        │
        ├─ 2. configureDropEventsService()
        │      wires PubSub callbacks into MinerEngine event handlers
        │
        ├─ 3. TwitchAPIClient.getAccessToken()
        │      └── PubSubClient.updateAccessToken(token)
        │          PubSubClient.connect()  [WebSocket handshake]
        │
        ├─ 4. WatchSessionManager.setUserId(account.id)
        │
        └─ 5. runMiningLoop() [Task — runs until stopped]
               │
               ├── DropsService.getActiveCampaigns()
               ├── claimReadyDrops()
               ├── selectBestCampaign()   [most unclaimed drops, soonest end]
               ├── DropsService.findLiveChannels(forGame:)
               ├── selectBestChannel()   [respects ACL whitelist if present]
               │
               ├── DropEventsService.startWatching(userId:channelId:)
               │     └── PubSubClient.listen([user-drop-events, video-playback])
               │
               ├── WatchSessionManager.startWatching(channel:campaignId:)
               │     └── SpadeBeaconService.sendBeacon() every 59s
               │
               └── inner watch loop (every 60s):
                     ├── DropsService.getOverallProgress() → onProgressUpdate callback
                     └── claimReadyDrops()
```

**Real-time interrupt path** (concurrent with the above):

```
PubSubClient receives message
  └── DropEventsService parses
        ├── drop-progress  → MinerEngine.handleDropProgress() → UI progress update
        ├── drop-claim     → MinerEngine.handleDropClaim()    → TwitchAPIClient.claimDrop()
        └── stream-down    → MinerEngine.handleStreamDown()   → shouldSwitchChannel = true
                                                                 inner watch loop exits
                                                                 runMiningLoop() selects new channel
```

---

## 6. UI Architecture

### `NavigationModel` (@MainActor @Observable)

Central navigation state. Owns `MinerManager`, and exposes:

| Property | Purpose |
|---|---|
| `selectedItem: SidebarItem?` | Current sidebar selection |
| `columnVisibility` | NavigationSplitView column state |
| `showAddAccountSheet: Bool` | Triggers Add Account sheet from any view |
| `minerLogs: [String: [LogEntry]]` | Per-miner live log buffers |

`setup()` wires `MinerManager.onLogMessage` into the log store and calls `MinerManager.setup()`.

### `MinerLoginService` (@MainActor @Observable)

State machine for the Add Account OAuth flow:

```
idle → starting → waitingForUser(code, url, expiresIn) → polling → succeeded(account)
                                                                  └→ failed(message)
```

Uses `TwitchAuthService` directly. Fully decoupled from the view layer.

### View Hierarchy

```
ContentView  (owns NavigationModel as @State)
├── NavigationSplitView
│   ├── SidebarView
│   │     ACCOUNTS section — per-miner rows (avatar, status dot, drops badge)
│   │     CAMPAIGNS section — badge with active campaign count
│   │     SYSTEM section — Logs, Settings
│   │
│   ├── [Content column — driven by NavigationModel.selectedItem]
│   │   ├── ActivityOverviewView     stats grid + MinerTableView  (default landing)
│   │   ├── AccountDetailView        per-miner stats, controls, log console
│   │   ├── CampaignsListView        miners grouped by current campaign
│   │   ├── AggregatedLogConsoleView all miner logs merged, auto-scroll
│   │   └── SettingsView
│   │
│   └── [Inspector column]
│       ├── AccountInspectorView     compact miner details + quick start/stop
│       ├── CampaignInspectorView    campaign watchers summary
│       └── SystemInspectorView      overall system stats
│
└── .sheet(isPresented: $nav.showAddAccountSheet)
      └── AuthRequiredSheet
            └── MinerLoginService drives auth state
                └── on .succeeded: MinerManager.addAccount() + startMiner()
                                   sidebar updates automatically via @Observable
```

All views receive state via `@Environment(NavigationModel.self)`. `MinerManager` is `@Observable` so SwiftUI re-renders automatically when `miners` changes — no manual `objectWillChange` calls needed.

### Menu Bar

`MinerApp.swift` provides a `MenuBarExtra` (`.menu` style) with active miner count, drops today, and Start All / Stop All / Quit actions alongside the main `WindowGroup`.

---

## 7. Project Structure

```
SwiftMiner/
├── project.yml                           XcodeGen spec → generates .xcodeproj
├── SwiftMiner.xcodeproj                  Generated Xcode project (do not hand-edit)
│
└── Sources/
    │
    ├── SwiftMinerCore/                 Static library — engine layer
    │   ├── Engine/
    │   │   ├── MinerEngine.swift         Per-account orchestrator (actor)
    │   │   └── MinerManager.swift        Multi-account supervisor (@MainActor)
    │   │
    │   ├── Models/
    │   │   ├── Account.swift             Twitch account + OAuth token model
    │   │   ├── APIModels.swift           Codable structs for all API responses
    │   │   ├── Campaign.swift            Campaign, Drop, Reward, Game models
    │   │   ├── Channel.swift             Channel model
    │   │   └── Progress.swift            Progress, OverallProgress, MiningSession, SessionStatus
    │   │
    │   ├── Services/
    │   │   ├── TwitchAuthService.swift   OAuth device-code flow + Keychain storage
    │   │   ├── TwitchAPIClient.swift     GraphQL HTTP client + rate limiter integration
    │   │   ├── DropsService.swift        Campaign / inventory / channel queries
    │   │   ├── WatchSessionManager.swift Spade beacon loop management
    │   │   ├── SpadeBeaconService.swift  minute-watched POST construction + sending
    │   │   ├── PubSubClient.swift        WebSocket PING/PONG + exponential backoff
    │   │   ├── DropEventsService.swift   PubSub message parser + typed callbacks
    │   │   ├── ClaimService.swift        Drop claim validation + execution
    │   │   └── CommunityPointsService.swift  (stub — future use)
    │   │
    │   └── Utils/
    │       ├── DebugTrace.swift          Categorised trace logger (actor)
    │       ├── DebugTracer.swift         TwitchAPIClient / PubSubClient trace extensions
    │       ├── Errors.swift              TwitchMinerError enum
    │       ├── GQLHashes.swift           All GraphQL persisted query SHA-256 hashes
    │       ├── Logger.swift              Lightweight logger utility
    │       └── RateLimiter.swift         Token bucket rate limiter (actor)
    │
    ├── SwiftMiner/                       SwiftMiner app source — SwiftUI layer
    │   ├── MinerApp.swift                @main App, MenuBarExtra, WindowGroup
    │   ├── NavigationModel.swift         Navigation state + log store (@MainActor)
    │   ├── MinerLoginService.swift       Add Account auth state machine (@MainActor)
    │   ├── ContentView.swift             Root NavigationSplitView + column routing
    │   ├── SidebarView.swift             Sidebar: accounts, campaigns, system sections
    │   ├── ActivityOverviewView.swift    Default landing: stats grid + miner table
    │   ├── MinerTableView.swift          SwiftUI Table of all miners with actions
    │   ├── AccountDetailView.swift       Per-miner detail + AccountInspectorView + SystemInspectorView
    │   ├── CampaignView.swift            Campaigns list + CampaignInspectorView
    │   ├── AuthRequiredSheet.swift       Add Account OAuth sheet UI
    │   ├── Settings.swift                @AppStorage settings model
    │   ├── SettingsView.swift            Settings form UI
    │   ├── AppModel.swift                Legacy single-engine bridge (superseded)
    │   ├── AuthView.swift                Legacy auth view (superseded)
    │   └── CampaignViews.swift           Legacy campaign/log views (partially superseded)
    │
```

> **Note:** `SwiftMiner.xcodeproj` is generated by XcodeGen from `project.yml`.
> Run `xcodegen generate` after adding or removing Swift source files.

---

## 8. Update Strategy

### GraphQL Query Registry (`GQLHashes.swift`)
All persisted query SHA-256 hashes are centralised in a single `enum GQLHashes`. When Twitch updates a query hash, only this one file changes. `TwitchAPIClient` auto-detects `PersistedQueryNotFound` in GQL response errors and throws a typed error, making regressions immediately visible.

### Protocol-Layer Isolation
Each service is a distinct Swift actor with a narrow public API. Swapping the PubSub reconnect strategy, the Spade beacon URL extraction, or the GQL request format requires changes to only one file.

### `DebugTrace` System
The `[GraphQL]`, `[PubSub]`, `[Spade]`, `[Claim]` trace categories let developers observe every external call at runtime without a debugger attached. Useful for catching Twitch API contract changes quickly. Enable via `MinerEngine.setDebugTraceEnabled(true)`.

### Rate Limiter
The 5 req/s token bucket is a single constructor parameter — trivial to adjust if Twitch changes their GraphQL rate-limiting policy.

---

## 9. Known Limitations / Technical Debt

| # | Area | Description |
|---|---|---|
| 1 | **Multi-account Keychain** | `TwitchAuthService` uses one Keychain slot per clientId. Accounts are not individually namespaced, so only one account survives a restart. Fix: key Keychain entries by `account.id` or `account.username`. |
| 2 | **No account persistence on launch** | `MinerManager.setup()` is a no-op placeholder. Accounts added during a session are lost after quit. Needs Keychain enumeration on startup. |
| 3 | **No campaign data in `ManagedMiner`** | `ManagedMiner.currentCampaign` is a `String?` name only. Full `Campaign` objects live inside each `MinerEngine`. `CampaignsListView` cannot show drop-level progress without querying each engine. |
| 4 | **Channel selection — first match only** | `selectBestChannel()` returns the first live channel. No viewer-count heuristic, no preference for channels not already watched by another miner. |
| 5 | **No watch-time persistence** | `MiningSession.totalWatchTime` resets on engine stop. Lifetime statistics are not written to disk. |
| 6 | **Legacy files present** | `AppModel.swift`, `AuthView.swift`, `CampaignViews.swift` are from the single-engine era. Still compile but are not used by the current navigation. Should be removed once confirmed as dead code. |
| 7 | **`CommunityPointsService` stub** | File exists but contains no implementation. Community points auto-claim is not yet supported. |
