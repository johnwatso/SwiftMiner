# SwiftMinerCore Documentation

## Table of Contents

1. [Getting Started](#getting-started)
2. [Architecture Overview](#architecture-overview)
3. [API Reference](#api-reference)
4. [Authentication Guide](#authentication-guide)
5. [Mining Configuration](#mining-configuration)

## Getting Started

### Prerequisites

Before using SwiftMinerCore, you need:

1. **Twitch Developer Account**: Register at [dev.twitch.tv](https://dev.twitch.tv)
2. **OAuth Client ID**: Create a new application in the Twitch Developer Console
3. **OAuth Client Secret**: Generated with your application
4. **Redirect URI**: Set to `http://localhost` for device code flow

### Installation

1. Clone the repository
2. Generate the project: `xcodegen generate`
3. Open `SwiftMiner.xcodeproj` in Xcode 16+
4. Build the `SwiftMiner` scheme

## Architecture Overview

### Core Components

```
┌─────────────────────────────────────────────────────────┐
│                    MinerEngine (actor)                   │
│  - Orchestrates mining lifecycle                         │
│  - Manages all services                                  │
│  - Handles state transitions                             │
└─────────────────────────────────────────────────────────┘
                            │
        ┌───────────────────┼───────────────────┐
        │                   │                   │
        ▼                   ▼                   ▼
┌───────────────┐  ┌────────────────┐  ┌─────────────────┐
│   TwitchAuth  │  │  TwitchAPI     │  │  SecureToken    │
│   Service     │  │  Client        │  │  Storage        │
│               │  │                │  │                 │
│ - Device code │  │ - GraphQL      │  │ - Keychain      │
│ - Token poll  │  │ - REST         │  │ - Encrypt/Dec   │
│ - Refresh     │  │ - JSON decode  │  │ - Store/Retrieve│
└───────────────┘  └────────────────┘  └─────────────────┘
                            │
        ┌───────────────────┼───────────────────┐
        │                   │                   │
        ▼                   ▼                   ▼
┌───────────────┐  ┌────────────────┐  ┌─────────────────┐
│ DropsService  │  │ WatchSession   │  │ ClaimService    │
│               │  │ Manager        │  │                 │
│ - Campaigns   │  │ - Heartbeat    │  │ - Claim drops   │
│ - Inventory   │  │ - Session mgmt │  │ - Queue mgmt    │
│ - Progress    │  │ - Channel sel  │  │ - Auto-claim    │
└───────────────┘  └────────────────┘  └─────────────────┘
```

### Data Flow

1. **Authentication** → `TwitchAuthService` → `SecureTokenStorage`
2. **API Requests** → `TwitchAPIClient` → Twitch GraphQL/REST
3. **Drop Tracking** → `DropsService` → Campaign/Progress data
4. **Watch Sessions** → `WatchSessionManager` → Heartbeat polling
5. **Claiming** → `ClaimService` → GraphQL mutation

## API Reference

### MinerEngine

The main entry point for all mining operations.

#### Initialization

```swift
let engine = MinerEngine(
    clientId: String,
    clientSecret: String,
    autoClaimDrops: Bool = true,
    rotateChannels: Bool = true,
    pollingInterval: TimeInterval = 30
)
```

#### Methods

| Method | Description | Returns |
|--------|-------------|---------|
| `startAuthentication()` | Begin device code auth flow | `DeviceCodeResponse` |
| `completeAuthentication(deviceCode:)` | Complete auth with device code | `Account` |
| `loadSavedAccount()` | Load account from keychain | `Account` |
| `startMining()` | Start the mining loop | `Void` |
| `stopMining()` | Stop mining | `Void` |
| `pauseMining()` | Pause mining | `Void` |
| `resumeMining()` | Resume paused mining | `Void` |

### TwitchAuthService

Handles OAuth 2.0 device code authentication.

#### Methods

| Method | Description | Returns |
|--------|-------------|---------|
| `requestDeviceCode()` | Request new device code | `DeviceCodeResponse` |
| `pollForToken(deviceCode:)` | Poll for token completion | `Account` |
| `refreshToken(_:)` | Refresh access token | `TokenResponse` |
| `cancelPolling()` | Cancel polling task | `Void` |

### DropsService

Manages drop campaigns and tracking.

#### Methods

| Method | Description | Returns |
|--------|-------------|---------|
| `fetchCampaigns(forceRefresh:)` | Get all campaigns | `[Campaign]` |
| `getActiveCampaigns()` | Get active campaigns only | `[Campaign]` |
| `fetchInventory()` | Get drop progress | `[DropProgress]` |
| `getCampaign(id:)` | Get specific campaign | `Campaign` |
| `getClaimableDrops()` | Get ready-to-claim drops | `[DropProgress]` |
| `getInProgressDrops()` | Get in-progress drops | `[DropProgress]` |
| `getOverallProgress()` | Get overall statistics | `OverallProgress` |

## Authentication Guide

### Device Code Flow

1. **Request Device Code**
   ```swift
   let deviceCode = try await engine.startAuthentication()
   ```

2. **Display to User**
   ```
   Visit: https://www.twitch.tv/activate
   Enter code: ABC123
   ```

3. **User Authorization**
   - User visits the URL on any device
   - Enters the user code
   - Logs in to Twitch
   - Authorizes the application

4. **Token Exchange**
   ```swift
   let account = try await engine.completeAuthentication(deviceCode: deviceCode.deviceCode)
   ```

5. **Token Storage**
   - Access token stored in memory
   - Refresh token stored in Keychain
   - Automatic refresh when expired

### Token Refresh

Tokens are automatically refreshed when:
- Access token is expired (or within 5 minutes of expiry)
- API returns 401 Unauthorized
- Loading saved account with expired token

## Mining Configuration

### Engine Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `autoClaimDrops` | Bool | `true` | Automatically claim completed drops |
| `rotateChannels` | Bool | `true` | Rotate between eligible channels |
| `pollingInterval` | TimeInterval | `30` | Seconds between mining loop iterations |

### State Machine

```
idle → authenticating → idle → fetching_campaigns → watching → claiming → watching
  ↑        ↓                ↑                           ↓
  └──── stopped ───────────┘                           ↓
          ↑                                            ↓
          └────────────── error ←──────────────────────┘
```

### State Descriptions

| State | Description |
|-------|-------------|
| `idle` | Engine is ready, not mining |
| `authenticating` | Performing OAuth authentication |
| `fetching_campaigns` | Loading campaign data from Twitch |
| `watching` | Actively watching streams |
| `claiming` | Claiming completed drops |
| `paused` | Mining temporarily paused |
| `stopped` | Mining stopped completely |
| `error` | Error occurred (includes message) |

## Error Handling

All errors conform to `LocalizedError`:

```swift
do {
    try await engine.startMining()
} catch let error as MinerEngineError {
    print("Mining error: \(error.localizedDescription)")
} catch {
    print("Unknown error: \(error.localizedDescription)")
}
```

### Common Errors

| Error | Cause | Solution |
|-------|-------|----------|
| `notAuthenticated` | No account loaded | Call `loadSavedAccount()` or authenticate |
| `noActiveCampaigns` | No campaigns running | Wait for new campaigns |
| `engineAlreadyRunning` | Mining already active | Call `stopMining()` first |
| `tokenRefreshFailed` | Refresh token expired | Re-authenticate with device code |

## Best Practices

1. **Always handle authentication errors** - Token expiry is common
2. **Check state before operations** - Use `currentState` property
3. **Add state listeners** - Monitor engine state changes
4. **Graceful shutdown** - Call `stopMining()` before app termination
5. **Secure credentials** - Never hardcode client ID/secret

## Troubleshooting

### Authentication Issues

**Problem**: Device code expires before authorization
- **Solution**: Request new device code (expires in ~15 minutes)

**Problem**: Token refresh fails
- **Solution**: Re-authenticate with fresh device code

### Mining Issues

**Problem**: No active campaigns
- **Solution**: Wait for Twitch drops campaigns to be active

**Problem**: Drops not progressing
- **Solution**: Verify channel has drops enabled, check Twitch account linkage

## Support

For issues and feature requests, please open an issue on the repository.
