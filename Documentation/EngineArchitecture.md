# SwiftMinerCore Engine Architecture

SwiftMinerCore is built around actor-isolated mining engines. A single `MinerEngine` manages one Twitch account. `MinerManager` owns one engine per account and presents a consolidated, main-actor-safe view to the macOS app.

## MinerEngine

`MinerEngine` is an actor that owns the mutable mining state for one account.

Main responsibilities:

- load or receive an authenticated account
- refresh Twitch campaign and inventory data
- apply priority, exclusion, badge/emote, account-link, and stream-avoidance preferences
- select the next campaign and channel to mine
- run and stop watch sessions
- listen for PubSub drop and stream events
- claim ready drops
- report status, campaigns, progress, claimed drops, errors, and log messages through callbacks

The public entry points used by the app are:

- `setAccount(_:)`
- `authenticate()`
- `start()`
- `stop()`
- `forceRefresh()`
- `claimAllDrops()`
- `getCurrentProgress()`
- preference update methods such as `updateMiningPreferences(...)`, `updateMiningStrategy(_:)`, and `updateNotificationPreference(enabled:)`

## Engine Services

Each engine creates its own service graph:

```text
MinerEngine
  -> TwitchAuthService
  -> TwitchAPIClient
  -> DropsService
     -> InventoryService
  -> WatchSessionManager
     -> SpadeBeaconService
     -> CommunityPointsService
  -> PubSubClient
  -> DropEventsService
  -> ClaimService
  -> NotificationService when claim notifications are enabled
```

The services are actor-based where they hold mutable state or perform long-running coordination. Models passed between services conform to `Sendable` where needed.

## Authentication And Tokens

Authentication uses Twitch device-code login through `TwitchAuthService`. The app shows the user code and verification URL, then the auth service polls Twitch until the account is approved.

The default client ID is Twitch's Android app client ID, matching the behavior of TwitchDropsMiner. A custom client ID can still be supplied by the app configuration.

Tokens are saved through the `TokenStore` protocol. `KeychainTokenStore` is the default app store and preserves the legacy encrypted local token format. `SQLiteTokenStore` is available for database-backed service flows.

When a token refresh succeeds, `TwitchAuthService` notifies the engine so `TwitchAPIClient` and `PubSubClient` can receive the fresh access token.

## Mining Loop

The engine loop follows this shape:

```text
start
  -> load account or use setAccount(_:)
  -> configure watch, PubSub, and drop event handlers
  -> fetch campaigns and inventory
  -> filter mineable campaigns
  -> select campaign by strategy and priority settings
  -> select an eligible live channel
  -> start WatchSessionManager
  -> send Spade watch beacons
  -> update progress from inventory, GraphQL, and PubSub
  -> claim ready drops
  -> rescan or switch channel when the target is complete, blocked, offline, or stalled
```

The loop periodically refreshes campaigns, polls claimable inventory while actively mining, and uses PubSub stream events to react faster when a stream goes offline.

## Watch Sessions

`WatchSessionManager` owns the active `WatchSession` for an engine.

Before starting a session, it validates the channel and fetches a playback access token. It then fetches the broadcast ID when available, starts a heartbeat loop, and sends Spade beacons at `SpadeBeaconService.watchInterval`.

The active session tracks:

- channel ID and login
- campaign ID
- game name and game ID
- broadcast ID
- start time
- session state
- total local watch time
- last heartbeat time and transport

Only one watch session can run per engine at a time.

## Campaign Selection

Campaign selection is constrained by account eligibility and app preferences.

The engine considers:

- campaign time window
- linked-account requirements
- unclaimed drops
- drop preconditions
- priority games
- excluded games
- mining strategy
- badge/emote campaign inclusion
- live channel availability
- duplicate stream avoidance across accounts
- followed/subscribed streamer priority

If a claim or inventory refresh means the current campaign is no longer mineable, the engine marks the session for switching and immediately rescans candidates.

## Status And Callbacks

`MinerEngine` emits `SessionStatus`:

- `idle`
- `authenticating`
- `fetchingCampaigns`
- `watching`
- `claiming`
- `waitingForStream`
- `paused`
- `stopped`
- `error`
- `idleNoEligibleCampaigns`
- `blockedAccountNotLinked`

Callbacks are set with methods such as `setStatusChangeHandler`, `setCampaignUpdateHandler`, `setProgressUpdateHandler`, `setDropClaimedHandler`, `setErrorHandler`, and `setLogMessageHandler`.

`MinerManager` maps these engine statuses into UI-facing miner state and keeps the app on the main actor.

## Debugging

`setDebugTraceEnabled(_:)` forwards detailed GraphQL, PubSub, Spade, and claim traces into the engine log callback.

`setDebugBypassLinkRequirement(_:)` is a testing-only path that allows the engine to exercise the watch pipeline without normal account-link eligibility checks. It should not be used for normal mining.
