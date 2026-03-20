<p align="center">
  <img src="assets/readme/TM Icon.png" width="120" alt="SwiftMiner Icon">
</p>

<h1 align="center">SwiftMiner</h1>

<p align="center">
  Native macOS Twitch Drops supervisor for multi-account mining
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2026+-blue">
  <img src="https://img.shields.io/badge/swift-6.0-orange">
  <img src="https://img.shields.io/badge/architecture-Universal%20(Apple%20Silicon%20%2B%20Intel)-black">
  <img src="https://img.shields.io/badge/license-GPLv3-blue">
  <img src="https://img.shields.io/badge/status-active%20development-orange">
</p>

---

## Why SwiftMiner Exists

Managing Twitch Drops across multiple accounts is messy.

- Progress is fragmented  
- Campaigns disappear once completed  
- Running multiple miners is clunky

SwiftMiner was built to fix that, especially for people who just want this running on their own Mac.

- Native macOS app  
- Easy multi-account management in one place  

It acts as a **supervisor layer**, giving you a single, consistent view of everything.

> Built on the ideas and groundwork of  
> https://github.com/DevilXD/TwitchDropsMiner

---

## Usage Notes

- Tested with up to **5 concurrent miner instances**
- Running more than this is **untested**
- Excessive automation **may violate Twitch policies**

Use this tool at your own risk. You are responsible for how you use it.

---

## Preview

<p align="center">
  <img src="assets/readme/v0.0.1 UI Example.png" alt="SwiftMiner Dashboard Preview">
</p>

---

## One Dashboard. All Drops.

SwiftMiner aggregates every campaign across every account into a single view.

- Always shows campaigns, even if already claimed  
- Prioritised ordering: **Claimable -> In Progress -> Available**  
- Drops stay attached to campaigns with no disappearing UI  

This becomes your **source of truth**.

---

## Multi-Account, Done Properly

Each account runs as its own isolated miner.

SwiftMiner brings them together:

- Start or stop individually or all at once  
- See which accounts are actively mining  
- Track contribution per account  

No more juggling multiple apps or windows.

---

## Smart Progress, Not Noise

Instead of duplicating or averaging data, SwiftMiner shows:

- **Best Progress** across all miners  
- **Active Miners** per drop  
- **Clear completion state**  

You know exactly where you stand, instantly.

---

## Fully Automated

Once running, SwiftMiner handles the rest:

- Selects the best available stream  
- Tracks watch progress  
- Automatically claims drops  

Set it up once, let it run.

---

## Native macOS Experience

Built in SwiftUI for macOS 26+.

- Designed around modern macOS UI patterns  
- Menu bar integration  
- Fast, minimal, and responsive  

This is not a wrapper or port.

---

## Install

Download from https://github.com/johnwatso/SwiftMiner/releases

1. Download the latest `.zip`  
2. Move `SwiftMiner.app` to `/Applications`  
3. Launch the app and add your account  

Updates are handled via Sparkle.

### System Requirements

- macOS 26+
- Internet access
- A Twitch account for device login
- Release builds are universal macOS binaries and support both Apple Silicon (`arm64`) and Intel (`x86_64`)

---

## Authentication

Uses Twitch OAuth device flow.

1. Click **Add Account**  
2. Visit https://www.twitch.tv/activate  
3. Enter code and log in  

Supports multiple accounts.

---

## Architecture (High-Level)

```
SwiftUI App (Dashboard + Control)
        ↓
Multi-Miner Manager
        ↓
Per-Account Miner Engines
        ↓
Auth • API • Drops • Watch • Claim • PubSub
```

---

## Requirements

- macOS 26+
- Apple Silicon or Intel Mac
- Xcode 16+ (for building)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

### Architecture Notes

- Debug builds in Xcode use the active architecture on the current Mac
- Release and Archive builds use the standard macOS universal architecture set (`arm64` + `x86_64`)

---

## Status

Active development. Expect iteration and change.

---

## Contributing

- Keep PRs small and focused  
- Include screenshots for UI changes  
- Write clear summaries  

---

## License

GPLv3
