# SwiftMiner Discord Help

## What is SwiftMiner?

SwiftMiner helps automate Twitch Drops so you don't need to leave streams open all day yourself.

SwiftBot is the Discord bot companion that:
- helps connect your Twitch account
- sends important Drop notifications
- lets you check status with `/miner`

If you're seeing these messages, someone in your Discord server is using SwiftMiner and enabled access for you.

---

## What SwiftBot can do

SwiftBot can:
- help connect your Twitch account
- notify you when Drops are claimed
- let you check your current status
- let you reconnect Twitch if your session expires

SwiftBot does **not**:
- post messages as you
- access your Discord account
- read your DMs
- access your Twitch password

---

## Why am I getting these DMs?

SwiftBot only sends DMs when something important happens with your Drops.

You won't get spam, constant progress updates, or random notifications.

### Messages you might see

| Message | What it means |
|---------|--------------|
| **Drop claimed** | A Twitch Drop was successfully claimed for you. |
| **Campaign complete** | All available Drops for a campaign have been earned. |
| **Twitch connection expired** | Your Twitch session needs reconnecting before Drops can continue. |
| **Link Twitch for {game}** | A game publisher account still needs linking before Drops can be claimed. |
| **Welcome back** | SwiftMiner briefly lost connection but recovered successfully. |

### Messages you will NOT get

- Constant heartbeat notifications
- Stream activity spam
- Messages every few minutes
- Unrelated Discord notifications

---

# Getting Started

## Step 1: Connect your Discord account

Your Discord account only becomes connected to SwiftMiner after you use a `/miner` command yourself.

For example:
- `/miner action:setup`
- `/miner action:status`

Once connected, you'll receive a welcome DM explaining how everything works.

---

## Step 2: Connect your Twitch account

SwiftMiner needs permission to claim Drops on your behalf.

### Setup steps

1. Send `/miner action:setup`
2. SwiftBot will send you an activation code
3. Open **twitch.tv/activate**
4. Sign in to Twitch
5. Enter the activation code
6. Wait for the confirmation message

Once complete, SwiftMiner will automatically watch for eligible Drops.

---

## Reconnecting Twitch later

Sometimes Twitch sessions expire — especially after password changes or revoked permissions.

If that happens:
1. Run `/miner action:setup`
2. Complete the Twitch activation steps again

The process usually takes less than a minute.

---

# Slash Commands

You can DM SwiftBot directly or use commands in supported servers.

| Command | Description |
|---------|-------------|
| `/miner` | View your current status and active Drops |
| `/miner action:setup` | Connect or reconnect your Twitch account |
| `/miner action:status` | Quick summary of current mining activity |

---

# Troubleshooting

## My Twitch connection keeps expiring

Try the following:

1. Re-run `/miner action:setup`
2. Make sure your Twitch password hasn't changed recently
3. Check that Twitch hasn't revoked app access

If the issue continues, contact the person managing SwiftMiner in your server.

---

## I'm not receiving any DMs

Check the following:
- Have you completed Twitch setup?
- Are there active Twitch Drops campaigns right now?
- Is SwiftMiner currently online?

Not every game has Drops active all the time.

---

## I already linked Twitch, but a game still says linking is required

Some publishers require an additional account connection outside of Twitch itself.

Examples include:
- EA
- Ubisoft
- Riot
- other publisher accounts

To fix this:
1. Open the game's Twitch Drops page
2. Look for **Link Account** or **Connect**
3. Complete the publisher account connection

Once linked, Drops for that game should work normally.

---

## My activation code expired

Activation codes only stay valid for a few minutes.

If yours expired:
- run `/miner action:setup` again
- a new code will be generated automatically

---

## I want to stop receiving DMs

Please contact the person managing SwiftMiner in your server and ask them to remove your access.

Self-service unlinking is not available yet.

---

# Privacy

### SwiftBot stores:
- your Discord user ID
- your Twitch username (after setup)
- setup completion status

### SwiftBot does NOT store:
- your Twitch password
- your Twitch login credentials
- your Twitch viewing history
- your Twitch inventory

Twitch sign-in happens directly through Twitch.

SwiftMiner handles Drop monitoring and claiming, while SwiftBot only sends updates and setup messages.

---

# Need more help?

If something still isn't working, contact the person managing SwiftMiner in your Discord server.

They can check logs, reconnect services, or help troubleshoot setup issues.
