<p align="center">
  <img src="assets/readme/TM Icon.png" width="120" alt="SwiftMiner Icon">
</p>

<h1 align="center">SwiftMiner</h1>

<p align="center">
  Native macOS Twitch Drops supervisor for multi-account mining
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2015+-blue">
  <img src="https://img.shields.io/badge/swift-6.0-orange">
  <img src="https://img.shields.io/badge/architecture-Apple%20Silicon-black">
  <img src="https://img.shields.io/badge/license-GPLv3-blue">
  <img src="https://img.shields.io/badge/status-active%20development-orange">
</p>

## Development Status

SwiftMiner is under active development.

Features, UI, and configuration may change frequently as the app evolves. Occasional breakage between releases is expected while core systems are refined and stabilized.

## Preview

<p align="center">
  <img src="assets/readme/v0.0.1 UI Example.png" alt="SwiftMiner Dashboard Preview">
</p>

## Overview

SwiftMiner is a native macOS application for supervising multiple Twitch Drops mining instances. It provides a clean, native interface to monitor and manage drops progress across multiple accounts simultaneously.

### Key Features

- **Multi-Miner Supervision** — Manage multiple Twitch accounts from a single dashboard
- **Native SwiftUI Interface** — Clean, macOS-native design that feels at home on your system
- **Automated Drop Progress** — Watch streams automatically and track progress across all miners
- **Smart Aggregation** — See your best progress across all accounts at a glance
- **Menu Bar Integration** — Quick status and controls without leaving your workflow
- **Auto-Claiming** — Automatically claim drops when they're ready

## Install

SwiftMiner installs are distributed through [GitHub Releases](https://github.com/johnwatso/SwiftMiner/releases).

1. Download the latest release from [GitHub Releases](https://github.com/johnwatso/SwiftMiner/releases).
2. Open the `.zip`.
3. Move `SwiftMiner.app` to `/Applications`.
4. Launch SwiftMiner and complete onboarding.

Future updates are handled in-app through Sparkle auto-updates.

## Authentication

SwiftMiner uses Twitch's OAuth device code flow for secure authentication.

### First-Time Setup

1. Launch SwiftMiner
2. Click **Add Account**
3. A device code will be displayed
4. Visit `https://www.twitch.tv/activate` on any device
5. Enter the code shown in SwiftMiner
6. Log in to your Twitch account and authorize the app
7. SwiftMiner will automatically detect successful authentication

### Multiple Accounts

SwiftMiner supports managing multiple Twitch accounts:

1. Go to **Accounts** in the sidebar
2. Click **Add Account** to authenticate additional accounts
3. Each account runs in its own isolated miner instance
4. Progress is aggregated across all miners for easy tracking

## Features

### Multi-Miner Management

- Add and manage multiple Twitch accounts
- Start/stop miners individually or all at once
- Per-account status and campaign tracking
- Isolated authentication and state per miner

### Drops Dashboard

- Unified view of all available drops across campaigns
- Aggregated progress showing best advancement across miners
- Active miner count per drop
- Expandable detail view for per-miner progress
- Smart sorting: Claimable → In Progress → Not Started

### Campaign Monitoring

- Real-time campaign status from Twitch
- Automatic best channel selection
- Priority and exclusion game lists
- Live stream detection with automatic fallback

### Progress Aggregation

Each drop displays:
- **Best Progress** — Maximum minutes watched across all miners
- **Active Miners** — Number of miners working on this drop
- **Completion Status** — Visual indicator when all miners have claimed

### Auto-Claiming

- Automatically claims drops when watch time is complete
- Configurable notifications for newly claimed drops
- Claim-all action for manual claiming

### Menu Bar Controls

- Quick start/stop all miners
- Live status indicator (idle/active)
- Drops claimed today counter
- One-click dashboard access

## Application Areas

| Area | Purpose |
| --- | --- |
| Activity Overview | High-level status of all miners and overall progress |
| Accounts | Manage connected Twitch accounts and per-miner status |
| Drops | Unified drops list with aggregated progress and expandable details |
| Logs | System-wide log aggregation from all miner instances |
| Settings | App configuration, notification preferences, and game filters |

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| `⌘⇧K` | Claim All Drops |
| `⌘⇧S` | Start All Miners |
| `⌘⇧X` | Stop All Miners |
| `⌘R` | Refresh Progress |

## Architecture

SwiftMiner is built with a clean separation between the engine layer and the app layer:

```
┌─────────────────────────────────────────────────────────┐
│              SwiftTwitchMinerApp (SwiftUI)              │
│  - Multi-miner management                                │
│  - Aggregated UI and progress tracking                   │
│  - Native macOS interface                                │
└─────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────┐
│                 SwiftTwitchMiner (Engine)                │
│  - MinerEngine: Single-account mining actor              │
│  - MinerManager: Multi-miner orchestration               │
│  - Services: Auth, API, Drops, Watch, Claim              │
└─────────────────────────────────────────────────────────┘
```

### Engine Layer (`SwiftTwitchMiner`)

- **MinerEngine** — Actor-based single-account mining lifecycle
- **TwitchAuthService** — OAuth device flow authentication
- **TwitchAPIClient** — GraphQL and REST API communication
- **DropsService** — Campaign fetching and progress tracking
- **WatchSessionManager** — Stream watching and heartbeat management
- **ClaimService** — Drop claiming and inventory management
- **PubSubClient** — Real-time drop events via WebSocket

### App Layer (`SwiftTwitchMinerApp`)

- **MinerManager** — Manages multiple `MinerEngine` instances
- **NavigationModel** — App state and navigation coordination
- **ContentView** — Root navigation split view
- **DropsListView** — Aggregated drops with multi-miner progress

## Storage

SwiftMiner stores application data in `~/Library/Application Support/SwiftMiner/`.

Common files include:

- `settings.json` — App preferences and game filters
- `accounts.json` — Account metadata (tokens stored in Keychain)

Authentication tokens are stored securely in macOS Keychain.

## Repository Layout

- `Sources/SwiftTwitchMiner/` — Reusable mining engine library
- `Sources/SwiftTwitchMinerApp/` — macOS SwiftUI application
- `Sources/SwiftTwitchMinerCLI/` — Command-line interface
- `Tests/` — Test suite
- `Documentation/` — Architecture and technical documentation

## Documentation

- [Architecture](Documentation/ARCHITECTURE.md)
- [Engine Architecture](Documentation/EngineArchitecture.md)
- [Technical Architecture](Documentation/TECHNICAL_ARCHITECTURE.md)

## Building from Source

### Requirements

- macOS 15.0+
- Xcode 16.0+
- Swift 6.0+

### Build

```bash
swift build
```

### Run App

```bash
swift run SwiftTwitchMinerApp
```

### Run Tests

```bash
swift test
```

## Configuration

### Environment Variables

| Variable | Description |
|----------|-------------|
| `TWITCH_CLIENT_ID` | Override the default Twitch client ID |

### Settings

Configure via **Settings** (⌘,):

- **Priority Games** — Games to prioritize when multiple campaigns are active
- **Excluded Games** — Games to ignore during mining
- **Claim Notifications** — Enable/disable drop claim notifications
- **Debug Tracing** — Enable detailed GraphQL/PubSub logging

## Troubleshooting

### Authentication Issues

**Problem**: Device code expires before authorization
- **Solution**: Request a new device code (expires in ~15 minutes)

**Problem**: Token refresh fails
- **Solution**: Remove and re-add the account

### Mining Issues

**Problem**: No active campaigns shown
- **Solution**: Ensure your Twitch account is linked to the game for the campaign

**Problem**: Drops not progressing
- **Solution**: Verify the channel has drops enabled and your account is linked

## Contributing

- Create a focused branch for each change.
- Keep updates small, clear, and easy to review.
- Include test notes and screenshots for behavior or UI changes.
- Open a pull request with a concise summary of what changed.

## License

SwiftMiner is released under the GPLv3 License.
