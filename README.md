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
- Ships signed and notarized release builds for macOS
- Supports Sparkle update checks, automatic updates, and unattended updates
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

Release builds are signed and notarized by Apple, and SwiftMiner includes Sparkle support for update prompts, automatic background checks, and unattended updates when macOS allows them.

> [!NOTE]
> Intel support depends on Apple's toolchain. If future macOS SDKs drop Intel support, SwiftMiner will move to Apple Silicon only.

## Releases vs. Development Builds

The latest GitHub release is the most stable version.

Building from the current `main` branch includes newer changes that have not been released yet. These builds may contain bugs, incomplete features, or breaking changes.

## Requirements

- macOS 26+
- Internet access

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

SwiftMiner is a native Xcode project split between the macOS app and `SwiftMinerCore`, which contains the mining engine, Twitch services, models, and account state.

## Notes and Risk

> [!CAUTION]
> This tool automates Twitch Drop viewing.
>
> Twitch's policies around automation are not always clearly defined, so there is some risk when using it.
>
> Proceed with caution and use at your own discretion.

<!-- markdownlint-disable-next-line MD028 -->
> [!WARNING]
> If the same account is used to watch a stream elsewhere (e.g. in a browser or another device),
> Twitch may prioritise that session instead.
> 
> This can stall drop progress or cause the miner to switch streams.

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

## Issues

Please raise a GitHub issue if something breaks, behaves unexpectedly, or needs attention.

SwiftMiner depends on Twitch's private behavior for Drops, watch progress, and claiming. Changes on Twitch's side can break the app without warning. To reduce downtime, enable automatic updates or unattended updates where possible so fixes are installed as soon as they are released.

## Related Docs

- [Architecture Overview](Documentation/ARCHITECTURE.md)
- [Engine Architecture](Documentation/EngineArchitecture.md)

## License

MIT
