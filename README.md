<p align="center">
  <img src="assets/readme/TM Icon.png" width="120" alt="SwiftMiner icon">
</p>

<h1 align="center">SwiftMiner</h1>

<p align="center">
  Native macOS app for automatically farming Twitch Drops while AFK.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2026+-blue" alt="Platform badge">
  <img src="https://img.shields.io/badge/swift-6.0-orange" alt="Swift badge">
  <img src="https://img.shields.io/badge/architecture-Universal%20(Apple%20Silicon%20%2B%20Intel)-black" alt="Architecture badge">
  <img src="https://img.shields.io/badge/license-MIT-blue" alt="License badge">
  <img src="https://img.shields.io/badge/status-active%20development-orange" alt="Status badge">
</p>

SwiftMiner is a macOS app that watches Twitch streams to farm Drops automatically while running in the background.

It is written in Swift using SwiftUI and standard macOS frameworks. Each account runs in its own isolated miner, and the app provides a single interface to monitor progress, claim state, and activity.

It can be used for a single account or multiple accounts.

## Acknowledgements

SwiftMiner was developed using [TwitchDropsMiner](https://github.com/DevilXD/TwitchDropsMiner) as a reference for expected behavior and edge cases.

That project established a working model for automating Twitch Drops progression. SwiftMiner implements a similar idea as a native macOS application, with a focus on multi-account management and a consolidated interface.

## Overview

SwiftMiner monitors active Twitch Drop campaigns and selects streams to watch based on:

- Campaign priority
- Time remaining
- Account eligibility

Each account progresses independently. The app handles stream selection, progress tracking, and claiming completed Drops.

## Why This Exists

I wanted something that runs natively on macOS without relying on browser automation or external tooling.

Existing solutions worked, but they were difficult to manage across multiple accounts. I often needed to run miners for friends who do not have their own systems running 24/7, which made coordination and visibility awkward.

SwiftMiner provides a single interface to manage multiple accounts, with release builds that are signed and notarized for macOS.

## What SwiftMiner Does

- Watches Twitch streams to farm Drops automatically
- Prioritizes campaigns based on time remaining and configured order
- Runs each account as an independent miner
- Tracks in-progress, claimable, and completed Drops in one view
- Automatically claims Drops when they complete
- Supports multiple accounts running in parallel
- Provides both a main window and a menu bar interface
- Uses Twitch device-code login, with no embedded browser
- Runs as a native macOS app built with Swift and SwiftUI

## Preview

<p align="center">
  <img src="Documentation/Images/1_Overview UI Example.png" alt="SwiftMiner overview screen">
  <img src="Documentation/Images/2_Miners UI Example.png" alt="SwiftMiner miners screen">
  <img src="Documentation/Images/3_Drops UI Example.png" alt="SwiftMiner drops screen">
</p>

## How It Works

- Each account runs its own miner engine
- The engine fetches active campaigns and eligibility from Twitch
- Campaigns are prioritized based on time remaining and user preference
- A stream is selected for the active campaign
- Watch progress is tracked via Twitch APIs
- Completed Drops are claimed automatically

The app sits on top of these engines and presents their state in a single interface.

## Install

Download the latest release from [GitHub Releases](https://github.com/johnwatso/SwiftMiner/releases).

1. Download the latest `.zip`
2. Move `SwiftMiner.app` to `/Applications`
3. Open the app and add an account
4. Allow notifications if you want claim alerts

Release builds support both Apple Silicon (`arm64`) and Intel (`x86_64`).

> [!NOTE]
> Intel support depends on Apple's toolchain. If future macOS SDKs drop Intel support, SwiftMiner will move to Apple Silicon only.

## Releases vs. Development Builds

The latest GitHub release is the most stable version.

Building from the current `main` branch includes newer changes that have not been released yet. These builds may contain bugs, incomplete features, or breaking changes.

## First Run

SwiftMiner uses Twitch device-code authentication.

1. Click `Add Account`
2. Visit [twitch.tv/activate](https://www.twitch.tv/activate)
3. Enter the code shown in the app
4. Sign in and approve access

Accounts are restored on launch after being added.

> [!CAUTION]
> OAuth tokens are stored in `~/Library/Application Support/com.swiftminer/` in encrypted form.
>
> The encryption key is tied to the machine, not your macOS login. Access to the machine allows decryption and reuse of tokens.

## Requirements

- macOS 26+
- Internet access

For building from source:

- Xcode 16+
- XcodeGen

## Building From Source

Generate the Xcode project:

```bash
xcodegen generate
open SwiftMiner.xcodeproj
```

Build the app:

```bash
xcodebuild -project SwiftMiner.xcodeproj -scheme SwiftMiner -destination 'platform=macOS' build
```

Run the tests:

```bash
xcodebuild -project SwiftMiner.xcodeproj -scheme SwiftMiner -destination 'platform=macOS' test
```

## Configuration

The app reads `TWITCH_CLIENT_ID` from the environment if provided.

```bash
export TWITCH_CLIENT_ID=your_client_id
```

## Project Layout

```text
Sources/
  SwiftMiner/       macOS app: UI, onboarding, dashboard, menu bar
  SwiftMinerCore/   mining engine, Twitch services, models, aggregation
Tests/              unit tests
Documentation/      architecture and implementation notes
scripts/            build and release automation
```

## Architecture

SwiftMiner is split into two layers:

1. `SwiftMiner`

   macOS app layer for UI, onboarding, settings, and notifications.

2. `SwiftMinerCore`

   Mining layer for engine state, accounts, Twitch APIs, watch sessions, and claims.

High-level flow:

```text
SwiftUI App
  -> AppModel / NavigationModel
  -> MinerManager
  -> per-account MinerEngine actors
  -> Twitch services: auth, API, watch, campaign, inventory, claim
```

## Notes and Risk

> [!WARNING]
> SwiftMiner sends watch activity to Twitch using an Android TV client profile.
>
> If the same account is used to watch a stream in a browser, Twitch may credit the browser session instead. This can stall drop progress or cause the miner to switch streams.

<!-- markdownlint-disable-next-line MD028 -->
> [!WARNING]
> Twitch may change how Drops or third-party automation is handled at any time. Accounts could be affected. Use with that in mind.

<!-- markdownlint-disable-next-line MD028 -->
> [!NOTE]
> Only one active stream per account contributes to drop progress.

<!-- markdownlint-disable-next-line MD028 -->
> [!NOTE]
> SwiftMiner is intended for personal use on your own machines.

<!-- markdownlint-disable-next-line MD028 -->
> [!NOTE]
> Performance depends on system resources, network conditions, and the number of accounts being managed.

## Related Docs

- [Architecture Overview](Documentation/ARCHITECTURE.md)
- [Engine Architecture](Documentation/EngineArchitecture.md)
- [Release Runbook](Documentation/RELEASING.md)

## Contributing

Keep pull requests small and focused.

- UI changes should include screenshots
- Engine changes should include or update tests where possible

## License

MIT
