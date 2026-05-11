# SwiftMiner Help

## What is SwiftMiner?

SwiftMiner is a native macOS app that automates Twitch Drops farming. It watches eligible streams in the background, tracks your progress, and claims completed Drops automatically. You can run multiple accounts at the same time, all from one interface.

---

## Getting Started

### Installation

1. Download the latest release from [GitHub Releases](https://github.com/johnwatso/SwiftMiner/releases)
2. Move `SwiftMiner.app` to `/Applications`
3. Open the app

> On first launch, macOS may warn you about an app downloaded from the internet. This is expected for any downloaded app — click **Open** to continue.

### Adding Your First Account

1. Click **Add Account** in the app
2. SwiftMiner will show a Twitch device-code login flow
3. Go to **twitch.tv/activate** in your browser
4. Sign in to Twitch and enter the code shown in SwiftMiner
5. Wait for the confirmation — your miner will start automatically

You can add multiple accounts and each runs independently.

---

## Main Window

The app uses a sidebar to navigate between sections.

| Section | What it shows |
|---------|--------------|
| **Overview** | Active campaigns, progress summaries, and what's currently being mined |
| **Miners** | Status of each account, current stream, health, and controls to start/stop |
| **Drops** | All drops: in-progress, claimable, completed, and upcoming |
| **Activity Log** | A running log of claims, errors, stream switches, and other events |
| **Discord** | SwiftBot integration settings (only visible if Discord features are enabled) |

### Overview

The Overview tab is your dashboard. It shows:
- Active campaigns and how much time remains
- Which miners are running and what they're watching
- Quick actions to manage campaigns

### Miners

Each account appears as its own miner. For each miner you can see:
- **Status**: Running, stopped, error, or needs attention
- **Current stream**: The channel being watched
- **Progress**: Drops earned today and overall
- **Health**: Whether the miner is progressing normally or appears stuck

You can start or stop individual miners, or sync all miners together if **Sync Miner State** is enabled in Settings.

A badge on the **Miners** sidebar item shows how many miners need attention (auth errors, account linking issues, etc.).

### Drops

The Drops tab shows every drop across all accounts:
- **In Progress**: Drops currently being farmed
- **Claimable**: Drops ready to claim
- **Completed**: Drops already claimed
- **Upcoming**: Drops from campaigns that haven't started yet

### Activity Log

A timestamped feed of everything SwiftMiner does. This is useful for understanding why a miner switched streams, when drops were claimed, or if something went wrong.

You can filter the log by category and export it if needed for troubleshooting.

---

## Settings

Open Settings with `⌘,` or from the app menu.

### General

| Setting | Description |
|---------|-------------|
| **App Presence** | Choose whether SwiftMiner appears in the Dock, the menu bar, or both |
| **Run in background when closed** | Keep miners running even if you close the main window |
| **Start at login** | Launch SwiftMiner automatically when you log in to macOS |
| **Start minimized** | Hide the main window on launch so it runs quietly in the background |
| **Check for updates** | Choose between Stable and Beta update channels |
| **Automatically check for updates** | Let Sparkle check for updates in the background |
| **Automatically download updates** | Download updates silently so they're ready to install |

> **App Management Permission:** On first update, macOS may ask for **App Management** permission. This is required for Sparkle to perform unattended updates. You should allow this if you want automatic updates.

### Accounts

Manage your connected Twitch accounts:
- Add new accounts
- Remove accounts you no longer want to mine
- Re-authenticate if a session expires

### Mining

| Setting | Description |
|---------|-------------|
| **Auto-claim drops** | Automatically claim completed drops |
| **Auto-claim channel points** | Automatically claim channel point bonuses when they appear |
| **Sync miner state** | Start or stop all miners together |
| **Auto-start on launch** | Begin mining automatically when the app opens (if already authenticated) |
| **Avoid duplicate streams** | Spread miners across different streams for the same campaign when possible |
| **Prioritise followed streamers** | Prefer channels you follow or subscribe to during stream selection |
| **Enable badges and emotes** | Include campaigns that only reward badges or emotes (no items) |
| **Anti-stall recovery** | Automatically restart a miner that appears stuck |

### Integrations

If Discord integration is enabled, you can configure:
- **SwiftBot connection**: Link the app to your Discord server for drop notifications
- **Notification preferences**: Choose which events are sent to Discord

See [Discord Help](./discord-help.md) for details on using SwiftBot.

### Advanced

| Setting | Description |
|---------|-------------|
| **Log level** | How much detail appears in the Activity Log (Debug, Info, Warning, Error) |
| **Show log console** | Display the live log panel in the UI |
| **Show activity log icons** | Show category icons next to log entries |
| **Prefer Steam artwork** | Use Steam store images instead of Twitch game artwork |

---

## Menu Bar Mode

If you set **App Presence** to Menu Bar Only or Dock + Menu Bar, SwiftMiner remains accessible from the macOS menu bar even when the main window is closed.

From the menu bar you can:
- See which miners are running
- Check recent drops claimed
- Open the main window
- Start or stop all miners
- Quit the app

This is useful if you want SwiftMiner to run quietly in the background.

---

## Menu Bar Commands

| Command | Shortcut | Description |
|---------|----------|-------------|
| Check for Updates… | — | Manually check for a new version |
| What's New | — | Open the release notes window |
| Refresh Progress | `⌘ R` | Force a refresh of all miner progress |
| Export Diagnostic Logs… | — | Save a redacted log file for troubleshooting |
| Raise Issue on GitHub… | — | Open the GitHub issue page in your browser |

---

## Notifications

SwiftMiner can send macOS notifications when:
- A drop is claimed
- A campaign completes
- A miner encounters an error
- Twitch authentication expires

Make sure you allow notifications when macOS prompts you, or enable them later in **System Settings > Notifications > SwiftMiner**.

---

## Troubleshooting

### A miner shows "Needs Auth"

Twitch sessions expire over time, especially after password changes or if you revoke app access.

1. Go to **Settings > Accounts**
2. Click **Reconnect** on the affected account
3. Follow the Twitch activation steps again

### A miner appears stuck

Make sure **Anti-stall recovery** is enabled in Settings. If a miner isn't making progress, SwiftMiner will try to restart it automatically.

Also check:
- Are there active Twitch Drops campaigns right now?
- Is the account eligible for the campaign?
- Does the game require an external account link (EA, Ubisoft, Riot, etc.)?

### Drops aren't progressing

- Only one stream session per account counts toward Drops. If you're watching Twitch in a browser or on another device, that session may take priority over SwiftMiner.
- Some campaigns require you to link a game publisher account before Drops can be claimed. Check the campaign page on Twitch.
- Not all games have active Drops at all times.

### I'm not receiving notifications

- Check that notifications are enabled in **System Settings > Notifications > SwiftMiner**
- Make sure **Do Not Disturb** or **Focus** modes aren't blocking alerts
- Discord DMs from SwiftBot are separate — see [Discord Help](./discord-help.md)

### Exporting logs for support

If something is broken and you need help:

1. Go to **Help > Export Diagnostic Logs…**
2. Save the file
3. Attach it when raising a GitHub issue or contacting support

Logs are automatically redacted to remove sensitive tokens and identifiers.

---

## Best Practices

- **Keep the app updated**: Twitch changes their systems without warning. Enable automatic updates so fixes arrive as soon as they're released.
- **Don't watch the same account elsewhere**: If SwiftMiner is farming Drops for an account, avoid watching Twitch with that account in a browser or on mobile at the same time.
- **Link publisher accounts early**: For games like EA Sports titles, Ubisoft games, or Riot titles, link your accounts on the Twitch Drops page before the campaign starts.
- **Check the Activity Log**: If something seems off, the log usually explains why a stream was switched or why a miner stopped.
- **Use the menu bar**: If you run SwiftMiner 24/7, set App Presence to Menu Bar Only to keep your Dock clean.

---

## Important Notes

- SwiftMiner is intended for personal use on your own machines and accounts.
- Each account runs independently — adding more accounts uses more system resources and bandwidth.
- Twitch may change how Drops or automation is handled at any time.
- Performance depends on your network, system resources, and how many accounts are active.

---

## Related Documentation

- [Discord Help](./discord-help.md) — Using SwiftBot and Discord integration
- [Architecture Overview](../../Documentation/ARCHITECTURE.md)
- [Engine Architecture](../../Documentation/EngineArchitecture.md)
