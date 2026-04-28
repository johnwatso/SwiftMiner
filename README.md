<p align="center">
  <img src="assets/readme/TM Icon.png" width="120" alt="SwiftMiner Icon">
</p>

<h1 align="center">SwiftMiner</h1>

<p align="center">
  Native macOS supervisor for Twitch Drops across multiple accounts
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2026+-blue" alt="Platform badge">
  <img src="https://img.shields.io/badge/swift-6.0-orange" alt="Swift badge">
  <img src="https://img.shields.io/badge/architecture-Universal%20(Apple%20Silicon%20%2B%20Intel)-black" alt="Architecture badge">
  <img src="https://img.shields.io/badge/license-MIT-blue" alt="License badge">
  <img src="https://img.shields.io/badge/status-active%20development-orange" alt="Status badge">
</p>

SwiftMiner is a SwiftUI macOS app for running Twitch Drops mining across multiple accounts. Each account runs in its own isolated miner engine, and the app shows campaigns, progress, and claim state for all of them in a single window.

It is built for personal use on macOS and is heavily inspired by the groundwork in [DevilXD/TwitchDropsMiner](https://github.com/DevilXD/TwitchDropsMiner).

## Preview

<p align="center">
  <img src="Documentation/Images/1_Overview UI Example.png" alt="Overview">
  <img src="Documentation/Images/2_Miners UI Example.png" alt="Miners">
  <img src="Documentation/Images/3_Drops UI Example.png" alt="Drops">
</p>

## What SwiftMiner Does

- Aggregates campaigns from all connected accounts into one dashboard
- Keeps completed, in-progress, and claimable drops visible in a consistent view
- Runs multiple miner engines independently instead of blending account state together
- Automatically tracks watch progress and claims completed drops
- Exposes app controls in both the main window and a menu bar extra
- Uses Twitch device-code login so accounts can be added without embedding a web view
- Ships with Sparkle-based in-app updates for release builds

## Why It Exists

I built SwiftMiner to solve a problem I kept running into while mining Twitch Drops for friends: progress was scattered across accounts, completed campaigns dropped out of the UI, and the existing tooling exposed raw miner state instead of something I could actually supervise at a glance.

SwiftMiner sits on top of the per-account miner engines and gives one control surface for the whole setup.

## Install

Download the latest release from [GitHub Releases](https://github.com/johnwatso/SwiftMiner/releases).

1. Download the latest `.zip`.
2. Move `SwiftMiner.app` to `/Applications`.
3. Open the app and add an account.
4. Allow notifications if you want claim alerts.

Release builds are universal macOS binaries and support both Apple Silicon (`arm64`) and Intel (`x86_64`).

> [!NOTE]
> Intel support is provided as long as the current macOS toolchain ships it. Once a future macOS release drops Intel from its SDK, SwiftMiner will follow suit and continue as an Apple Silicon-only build going forward.

## First Run

SwiftMiner uses Twitch OAuth device-code authentication.

1. Click `Add Account`.
2. Visit [twitch.tv/activate](https://www.twitch.tv/activate).
3. Enter the code shown by SwiftMiner.
4. Sign in and approve the device login.

After that, SwiftMiner can restore saved accounts and manage them from the main dashboard.

> [!CAUTION]
> SwiftMiner saves OAuth tokens to an encrypted file in `~/Library/Application Support/com.swiftminer/`. The encryption key is tied to your Mac's hardware UUID — not to your macOS login password. Physical or remote access to your machine is enough to decrypt this file and use the stored tokens to access your Twitch accounts.

## Requirements

- macOS 26+
- Xcode 16+ for local builds
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- Internet access

## Building From Source

Generate the Xcode project, then open or build it normally:

```bash
xcodegen generate
open SwiftMiner.xcodeproj
```

You can also build from the command line:

```bash
xcodebuild -project SwiftMiner.xcodeproj -scheme SwiftMiner -destination 'platform=macOS' build
```

Run tests with:

```bash
xcodebuild -project SwiftMiner.xcodeproj -scheme SwiftMiner -destination 'platform=macOS' test
```

## Configuration

The app resolves `TWITCH_CLIENT_ID` from the environment first and falls back to the bundled client ID when it is not set.

Example:

```bash
export TWITCH_CLIENT_ID=your_client_id
```

## Project Layout

```text
Sources/
  SwiftMiner/       SwiftUI macOS app, onboarding, dashboard, settings, menu bar UI
  SwiftMinerCore/   Actor-based mining engine, Twitch services, models, aggregation logic
Tests/              Unit tests for services, engine behavior, routing, and presentation
Documentation/      Architecture notes, release process, audits, and implementation docs
scripts/            Build and Sparkle release automation
```

## Architecture

SwiftMiner is split into two layers:

1. `SwiftMiner`
   The macOS app layer. It owns the SwiftUI dashboard, onboarding flow, settings, notifications, and menu bar integration.
2. `SwiftMinerCore`
   The mining layer. It contains the actor-based engine, account state, Twitch API/auth services, watch session management, drop claiming, and campaign aggregation.

High-level flow:

```text
SwiftUI App
  -> AppModel / NavigationModel
  -> MinerManager
  -> per-account MinerEngine actors
  -> Twitch auth, API, watch session, campaign, inventory, and claim services
```

That separation keeps the UI relatively thin while the mining logic stays testable in `SwiftMinerCore`.

## Notes And Risk

> [!WARNING]
> SwiftMiner sends watch beacons to Twitch presenting as an Android TV client (`tv.twitch.android.app`). If you open the same channel in a browser on a mining account, Twitch may start crediting watch time to the browser session instead. This can stall drop progress or cause the engine to switch channels unnecessarily. Avoid watching on the same account while SwiftMiner has it active.

> [!WARNING]
> SwiftMiner automates interactions with Twitch using the same client ID as the official Android app. Twitch's policies on third-party automation can change at any time, and accounts could be flagged. Use it at your own risk and review Twitch's current rules before running it unattended.

- SwiftMiner is intended for personal use on your own machines.
- The project has been exercised with several concurrent miners, but your own limits will depend on your machine, network, and account setup.

## Related Docs

- [Architecture Overview](Documentation/ARCHITECTURE.md)
- [Engine Architecture](Documentation/EngineArchitecture.md)
- [Release Runbook](Documentation/RELEASING.md)

## Contributing

Small, focused pull requests are easiest to review. If you change the UI, include screenshots. If you change engine behavior, include or update tests where practical.

## License

MIT
