# SwiftMiner Architecture

SwiftMiner is a native macOS app built with SwiftUI and SwiftMinerCore. The app owns presentation, settings, account onboarding, update controls, and notifications. SwiftMinerCore owns Twitch authentication, campaign data, watch sessions, claiming, and multi-account mining state.

## Runtime Shape

```text
MinerApp
  -> NavigationModel
     -> SQLiteManager
     -> MinerManager
        -> MinerEngine per account
           -> TwitchAuthService
           -> TwitchAPIClient
           -> DropsService
              -> CampaignDataService / InventoryService
           -> WatchSessionManager
              -> SpadeBeaconService
              -> CommunityPointsService
           -> PubSubClient / DropEventsService
           -> ClaimService
```

## App Layer

The SwiftUI app is centered around three long-lived objects:

- `MinerApp` creates shared app state, configures windows and the menu bar extra, requests notification permission, and starts background update checks.
- `NavigationModel` opens the local SQLite database, loads saved accounts, wires service/admin integrations, and owns navigation state.
- `AppModel` coordinates user actions such as starting/stopping miners, refreshing progress, claiming drops, and applying settings.

Settings are stored through `Settings.shared`. The Twitch client ID resolves from `TWITCH_CLIENT_ID` when present, then app settings where supported, then the built-in Twitch Android client ID used by the reference miner.

## Multi-Account Mining

`MinerManager` is the main multi-account coordinator. It is `@MainActor` and keeps UI-facing miner state in `ManagedMiner` values while owning the underlying `MinerEngine` actors.

Each Twitch account gets its own `MinerEngine`, API client, auth service, drops service, watch session manager, PubSub client, and claim service. This keeps account state isolated while still allowing the UI to aggregate progress across accounts.

The manager also coordinates cross-account behavior such as:

- starting and stopping one miner or all miners
- avoiding duplicate streams when possible
- applying priority and excluded game settings
- mapping engine `SessionStatus` values into user-facing `MinerStatus`
- maintaining per-account `AccountStateStore` data for the dashboard

## Persistence

SwiftMiner uses local application support storage under `~/Library/Application Support/SwiftMiner/`.

- `SQLiteManager` stores app/service data such as linked admin metadata and event outbox records.
- `TokenStore` abstracts account token persistence.
- `KeychainTokenStore` is the default token store used by the app and preserves the legacy encrypted-file token format.
- `SQLiteTokenStore` exists for services that need token persistence through the local database.

## Campaign Data

Campaign data starts with Twitch GraphQL/API responses and is normalized into SwiftMinerCore models.

- `TwitchAPIClient` performs GraphQL and Helix-style requests.
- `DropsService` exposes campaign, inventory, progress, and aggregate progress operations.
- `CampaignDataService` merges fresh campaign responses with inventory state for one account.
- `AggregatedCampaignDataService` and `CampaignStore` support multi-account campaign aggregation.
- `PrimaryStateResolver` and `MinerGameState` convert raw campaign/account state into UI-friendly activity states.

## Watch And Claim Flow

The engine loop repeatedly refreshes campaign state, chooses a mineable campaign, chooses an eligible live channel, and starts a watch session.

Watch sessions are handled by `WatchSessionManager`. Before watching, it verifies playback access and fetches a broadcast ID where available. While watching, it sends Spade beacons on the same interval used by the reference miner and auto-claims available channel points through `CommunityPointsService`.

Drop progress is updated from Twitch inventory/GraphQL polling and PubSub events. Completed drops are passed to `ClaimService`, and the engine rescans campaigns when claiming changes the current mineable target.

## Status Model

The core engine reports `SessionStatus` values:

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

The app maps these into `MinerManager.MinerStatus` and then into dashboard cards, table rows, menu bar state, and health indicators.
