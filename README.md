<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="Website/public/assets/landing/app-icon-light.webp">
    <source media="(prefers-color-scheme: light)" srcset="Website/public/assets/landing/app-icon-light.webp">
    <img src="Website/public/assets/landing/app-icon-light.webp" width="120" alt="SwiftMiner icon">
  </picture>
</p>

<h1 align="center">SwiftMiner</h1>

<p align="center"><strong>Native Twitch Drops mining for macOS.</strong></p>

<p align="center">
  Built in Swift for macOS, SwiftMiner automatically progresses and claims Twitch Drops across one or multiple accounts.
</p>

<p align="center">
  <a href="https://swiftminer.app/download/"><strong>Download SwiftMiner</strong></a> ·
  <a href="https://swiftminer.app/">Website</a> ·
  <a href="Documentation/README.md">Documentation</a> ·
  <a href="https://github.com/johnwatso/SwiftMiner/releases">GitHub Releases</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2014+-blue" alt="macOS 14 or later">
  <img src="https://img.shields.io/badge/swift-6.0-orange" alt="Swift 6">
  <img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT License">
</p>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="Website/public/assets/landing/overview-dark.webp">
    <source media="(prefers-color-scheme: light)" srcset="Website/public/assets/landing/overview-light.webp">
    <img src="Website/public/assets/landing/overview-light.webp" alt="SwiftMiner Overview">
  </picture>
</p>

## Highlights

- A focused macOS application built with Swift 6, SwiftUI, and native frameworks
- Automatic Twitch Drops progression and claiming
- Independent mining across multiple Twitch accounts
- Campaign prioritisation, exclusions, and stream selection controls
- Remote monitoring and management through the Web UI
- Discord notifications and remote actions through SwiftBot
- Universal releases for Apple silicon and Intel, signed and notarised for macOS
- Built-in update checks and optional unattended updates through Sparkle

## Installation

Download the latest stable version from [swiftminer.app](https://swiftminer.app/download/) or [GitHub Releases](https://github.com/johnwatso/SwiftMiner/releases), then move SwiftMiner to your Applications folder.

SwiftMiner requires macOS 14.0 or later and an internet connection. Release builds support Apple silicon and Intel Macs. See the [getting started guide](https://swiftminer.app/help/getting-started/) for setup help.

## Why SwiftMiner?

SwiftMiner began because I wanted a proper macOS app for managing Twitch Drops without coordinating several miners or virtual machines. A single place for accounts, progress, updates, and activity made that workflow much easier to look after.

It also became a practical way to explore modern Swift, SwiftUI, and Swift Concurrency in a real multi-account application designed specifically for macOS.

## Acknowledgements

[TwitchDropsMiner](https://github.com/DevilXD/TwitchDropsMiner) by [DevilXD](https://github.com/DevilXD) was an original inspiration for SwiftMiner and remains a valuable reference when Twitch behaviour changes. SwiftMiner is not a port and does not share its code.

[ShipHook](https://github.com/maxhewett/ShipHook) by [Max Hewett](https://github.com/maxhewett) powers SwiftMiner's build, signing, notarisation, update, and release pipeline. Max has also provided invaluable help throughout the project.

## Development

SwiftMiner is an Xcode project built primarily with Swift 6, SwiftUI, and macOS frameworks. Start with the [development guide](Documentation/DEVELOPMENT.md), [architecture overview](Documentation/ARCHITECTURE.md), and [engine architecture](Documentation/EngineArchitecture.md).

## Releases

[GitHub Releases](https://github.com/johnwatso/SwiftMiner/releases) contain stable builds. The `main` branch may include unreleased or incomplete work.

## Use at Your Own Risk

> [!WARNING]
> SwiftMiner is an unofficial third-party tool and is not affiliated with or endorsed by Twitch. It automates Twitch Drops viewing and claiming, and Twitch's rules, enforcement, or APIs may change at any time. This could interrupt functionality or affect accounts using the app, so use SwiftMiner at your own discretion and risk.

## License

SwiftMiner is available under the [MIT License](LICENSE).
