<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/readme/app-icon-dark.png">
    <source media="(prefers-color-scheme: light)" srcset="assets/readme/app-icon-light.png">
    <img src="assets/readme/app-icon-light.png" width="120" alt="SwiftMiner icon">
  </picture>
</p>

<h1 align="center">SwiftMiner — Native macOS Twitch Drops Automation</h1>

<p align="center">
  Automated Twitch Drops farming for macOS. Secure, native, and multi-account ready.
</p>

<p align="center">
  <strong><a href="https://swiftminer.app">swiftminer.app</a></strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2026+-blue" alt="Platform badge">
  <img src="https://img.shields.io/badge/swift-6.0-orange" alt="Swift badge">
  <img src="https://img.shields.io/badge/architecture-Universal%20(Apple%20Silicon%20%2B%20Intel)-black" alt="Architecture badge">
  <a href="https://github.com/johnwatso/SwiftMiner/releases"><img src="https://img.shields.io/github/downloads/johnwatso/SwiftMiner/total?label=downloads" alt="GitHub release downloads badge"></a>
  <img src="https://img.shields.io/badge/license-MIT-blue" alt="License badge">
  <img src="https://img.shields.io/badge/status-active%20development-orange" alt="Status badge">
</p>

## Highlights

- Web UI for remote monitoring and management
- Discord DM support via SwiftBot
- Notarized by Apple for trusted macOS installs
- Built-in update management with Sparkle

**SwiftMiner** is a high-performance, native macOS application designed to automate **Twitch Drops farming** across multiple accounts simultaneously. Built with Swift 6 and SwiftUI, it provides a lightweight, background-ready solution for claiming Twitch rewards without the need for browser automation or heavy external dependencies.

It is written in Swift using SwiftUI and standard macOS frameworks. Each account runs in its own isolated miner, and the app provides a single interface to monitor progress, claim state, and activity.

It can be used for a single account or multiple accounts.

## Acknowledgements

SwiftMiner was developed using [TwitchDropsMiner](https://github.com/DevilXD/TwitchDropsMiner) as a reference for expected behavior and edge cases.

That project established a working model for automating Twitch Drops progression. SwiftMiner implements a similar idea as a native macOS application, with a focus on multi-account management and a consolidated interface.

Release builds are produced with [ShipHook](https://github.com/maxhewett/ShipHook), which handles the build, signing, notarization, Sparkle appcast, and release publishing flow.

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

### Overview

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/readme/overview-dark.png">
    <source media="(prefers-color-scheme: light)" srcset="assets/readme/overview-light.png">
    <img src="assets/readme/overview-light.png" alt="SwiftMiner Overview">
  </picture>
</p>

### Miners

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/readme/miners-dark.png">
    <source media="(prefers-color-scheme: light)" srcset="assets/readme/miners-light.png">
    <img src="assets/readme/miners-light.png" alt="SwiftMiner Miners">
  </picture>
</p>

### Drops

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/readme/drops-dark.png">
    <source media="(prefers-color-scheme: light)" srcset="assets/readme/drops-light.png">
    <img src="assets/readme/drops-light.png" alt="SwiftMiner Drops">
  </picture>
</p>

### Activity Log

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/readme/activity-log-dark.png">
    <source media="(prefers-color-scheme: light)" srcset="assets/readme/activity-log-light.png">
    <img src="assets/readme/activity-log-light.png" alt="SwiftMiner Activity Log">
  </picture>
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

Download the latest release from the official website [swiftminer.app](https://swiftminer.app) or from [GitHub Releases](https://github.com/johnwatso/SwiftMiner/releases).

1. Download the latest `.zip`
2. Move `SwiftMiner.app` to `/Applications`
3. Open the app and add an account
4. Allow notifications if you want claim alerts

> [!TIP]
> **Security Prompt:** On first update or when enabling automatic updates, macOS may prompt for **"App Management"** permissions. This is expected and required for **Sparkle** to perform unattended/auto updates. You should allow this if you want the app to stay up-to-date automatically in the background.

Release builds support both Apple Silicon (`arm64`) and Intel (`x86_64`).

Release builds are signed and notarized through ShipHook, and SwiftMiner includes Sparkle support for update prompts, automatic background checks, and unattended updates when macOS allows them.

> [!NOTE]
> Intel is fully supported in current versions. However, since Apple is dropping Intel support starting in macOS 27, SwiftMiner may also drop Intel support in a future release.

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
