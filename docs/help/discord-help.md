# SwiftMiner Help

## What is SwiftMiner?

SwiftMiner is a Twitch Drops automation tool that someone in your Discord community runs on their Mac. It watches Twitch streams in the background and claims Drops automatically so you don't have to keep a stream open yourself.

SwiftBot is the Discord bot that sends you updates about your Drops, helps you set up your Twitch account, and lets you check progress.

If you're seeing this, someone in your server is running SwiftMiner and invited you to use it.

---

## Why am I getting these DMs?

SwiftBot sends you direct messages when something actually happens with your Drops. You won't get routine updates or spam — only when something is ready, finished, or needs your attention.

**Messages you might see:**

| Message | What it means |
|---------|--------------|
| **Drop claimed** | SwiftMiner claimed a Twitch Drop for you. Check your Twitch inventory to redeem it. |
| **Campaign complete** | All Drops in a campaign have been earned. Nothing left to do for this one. |
| **Twitch connection expired** | Your Twitch login session expired. You'll need to reconnect so SwiftMiner can keep claiming Drops. |
| **Link Twitch for {game}** | A game you prioritised requires linking your Twitch account to the game publisher. SwiftMiner can't do this part for you. |
| **Welcome back** | SwiftMiner had a brief issue but recovered and is working again. |

**You will not get:**
- "Still running" messages
- Progress updates every few minutes
- Random pings

---

## Getting Set Up

### Step 1: Link your Discord account

If an admin added you to SwiftMiner, your Discord account is already connected. You should have received a welcome DM from SwiftBot confirming this.

If you haven't received anything, ask the person running SwiftMiner to check that you're registered.

### Step 2: Link your Twitch account

SwiftMiner needs access to your Twitch account to claim Drops for you.

1. Send `/miner action:setup` to SwiftBot in a DM
2. You'll receive an activation code
3. Go to **twitch.tv/activate** in your browser
4. Sign in to Twitch (if you aren't already)
5. Enter the activation code
6. Wait for SwiftBot to confirm you're connected

That's it. SwiftMiner will start watching for Drops automatically.

### Reconnecting after your session expires

Twitch login sessions expire every so often — especially if you change your password or revoke access. If you get a "Twitch connection expired" DM, just run `/miner action:setup` again. It takes about 30 seconds.

---

## Slash Commands

You can DM SwiftBot directly. These commands work anywhere the bot can see you:

| Command | What it does |
|---------|-------------|
| `/miner` | Check your current status, active campaigns, and claimed Drops |
| `/miner action:setup` | Start or redo the Twitch linking flow |
| `/miner action:status` | Quick summary of what SwiftMiner is doing for you right now |

---

## Troubleshooting

### "Twitch connection expired" keeps happening

Try these in order:
1. Run `/miner action:setup` and re-link
2. Make sure you haven't changed your Twitch password recently
3. Check that your Twitch account is in good standing (not suspended or flagged)

If it still keeps happening, reach out to whoever runs SwiftMiner in your server — they can check the logs.

### I'm not getting any DMs at all

- Did you complete the Twitch setup flow? Run `/miner action:setup` if you're not sure.
- Are there active Drops campaigns right now? Not every game has Drops running all the time.
- Is the person running SwiftMiner online? SwiftMiner runs on their Mac, so if their computer is off, nothing happens.

### "Link Twitch for {game}" but I already linked my Twitch

Some game publishers (like EA, Ubisoft, etc.) require a **separate** account link on their own website or on Twitch's Drops page. SwiftMiner can't do this step automatically.

1. Go to the game's Twitch Drops campaign page
2. Look for "Link Account" or "Connect"
3. Link your game account there

Once that's done, SwiftMiner can claim Drops for that game normally.

### The activation code doesn't work

Activation codes expire after a few minutes. If yours expired, just run `/miner action:setup` again to get a fresh one.

### I want to stop receiving DMs

Reach out to whoever runs SwiftMiner in your server and ask them to remove your registration. There is no self-service unlinking right now.

---

## Privacy

**What SwiftBot stores:**
- Your Discord user ID
- Your Twitch username (after you link it)
- Whether you've completed setup

**What SwiftBot does NOT store:**
- Your Twitch password
- Your Twitch login tokens
- What streams you watched
- Your drop inventory

All Twitch authentication happens directly between your browser and Twitch. SwiftMiner (the Mac app) handles the actual claiming — SwiftBot just tells you when things happen.

---

## Need more help?

If something isn't covered here, reach out to the person running SwiftMiner in your Discord server. They have access to logs and can check if something is wrong on their end.
