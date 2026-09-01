# SwiftBot DM Contract

How SwiftMiner describes a Discord DM, and what SwiftBot is expected to render
from it. SwiftMiner decides *whether*, *when* and *about what*; SwiftBot owns
the embed — title, copy, artwork and buttons.

**Status: implemented on both sides.**

- SwiftMiner (build 2026090112) — `Sources/SwiftMinerService/Models/SwiftBotTypes.swift`
  (payload), `Sources/SwiftMinerService/SwiftMinerPortalLink.swift` (link building),
  `Sources/SwiftMinerService/WebDashboardAppScript.swift` (portal routes).
- SwiftBot — `Sources/SwiftBot/Models/SwiftMinerDMTypes.swift` (payload mirror),
  `Sources/SwiftBot/Services/SwiftMinerDMRouter.swift` (button rendering).

Keep the two enums and the route shapes in sync; the tests on each side assert
the same strings.

---

## 1. What changed

Five optional fields were added to `SwiftBotDMRequest`. Everything else is
unchanged, and payloads that omit them still decode, so SwiftBot can adopt them
incrementally.

| JSON key | Type | Meaning |
|---|---|---|
| `portal_url` | string? | Absolute deep link into the operator's web portal, already pointing at the page that explains or resolves this DM. |
| `portal_destination` | string? | What `portal_url` points at, so the button can be labelled without parsing the URL. |
| `issue_kind` | string? | The specific problem behind a broad message type. |
| `campaign_id` | string? | The campaign this DM is about, where one applies. |
| `help_url` | string? | Public help article on swiftminer.app covering this situation. |

### The one rule

**If `portal_url` is absent, render no portal button.** It is absent precisely
when the operator has no reachable public portal URL, so any fallback link would
404 for the recipient. A DM with no button is correct in that case.

`help_url` is independent — it may be present when `portal_url` is not, and is a
reasonable secondary link (or the only one) in that situation.

---

## 2. `portal_destination`

| Value | Lands on | Suggested button |
|---|---|---|
| `dashboard` | Portal root | **Open Dashboard** |
| `miner` | That miner's detail page | **View Miner** |
| `account_connection` | The account's Twitch connection state | **Reconnect Twitch** |
| `campaign` | One named campaign | **View Campaign** |
| `campaigns` | The campaign list | **View Campaigns** |
| `drops` | Completed drops | **View Drops** |

Labels are suggestions carried in Swift as
`SwiftBotPortalDestination.suggestedButtonLabel`. SwiftBot may override them, but
the same destination should read the same way in every DM.

Unknown values will appear if SwiftMiner adds a destination before SwiftBot knows
it. Treat an unrecognised `portal_destination` as `dashboard` and still render
the button — `portal_url` is always the authority on where it goes.

### Route shapes

Deep links are fragment routes under `/app`, parsed by the portal SPA:

```
https://portal.example.com/app
https://portal.example.com/app#/miner/<twitchAccountId>
https://portal.example.com/app#/campaign/<campaignId>
https://portal.example.com/app#/campaigns
https://portal.example.com/app#/account/connection
https://portal.example.com/app#/drops
```

Path segments are percent-encoded. SwiftBot should treat `portal_url` as opaque
and never construct these itself — the portal origin is per-operator.

---

## 3. `issue_kind`

Lets a DM name what is actually wrong. `account_action_required` in particular is
a catch-all whose title should never read "Needs a Look" when the cause is known.

| Value | Suggested title |
|---|---|
| `connection_expired` | **Twitch Connection Expired** |
| `account_link_required` | **Account Linking Required** |
| `account_link_delivery_pending` | **Rewards Waiting on an Account Link** |
| `subscription_required` | **Twitch Subscription Required** |
| `unknown` | **Action Required** |

`unknown` means SwiftMiner could not classify the cause, not that there is no
cause — `recovery_reason` still carries the detail. Fall back to the generic
title and show the reason as the body.

`account_link_delivery_pending` is not a milder `account_link_required`, it is a
different problem: the drops are already claimed on Twitch and the missing link
only stops the publisher handing them over in-game. Nothing is at risk of being
lost, so the DM must not tell the reader to go and earn rewards they already
hold. SwiftMiner sets it wherever it knows — the Pending reminder, the attention
banner's reminder, and the automatic warning — and the app's own wording matches.

Treat an unrecognised value as `unknown`.

---

## 4. Per-message-type payloads

What SwiftMiner sends today. "Category" is the visual treatment tier.

### Action required

| Type | `issue_kind` | `portal_destination` | Key fields |
|---|---|---|---|
| `reauth` | `connection_expired` | `account_connection` | `twitch_username` |
| `prioritised_game_needs_linking` | `account_link_required`, or `account_link_delivery_pending` when every blocked campaign is already claimed | `campaigns` | `affected_game`, `affected_game_id`, `campaign_name`, `miner_display_name` |
| `account_action_required` | classified, else `unknown` | `campaign` when `campaign_id` is set, else `miner` | `recovery_reason`, `affected_game`, `campaign_name` |

These should identify the affected miner, say what stopped working and what the
consequence is, and carry one primary button.

### Activity

| Type | `portal_destination` | Key fields |
|---|---|---|
| `campaign_completed` | `drops` | `campaign_id`, `campaign_name`, `affected_game`, `game_artwork_url` |
| `campaign_detected` | `campaign` | `campaign_id`, `campaign_name`, `affected_game`, `game_artwork_url` |
| `welcome_back` | `miner` | `twitch_username` |

Informational. A button is fine; they must not read as errors.

### Lifecycle

| Type | `portal_destination` | Notes |
|---|---|---|
| `welcome` | `dashboard` | Manual only, from the miner's Discord card. |
| `linked` | `dashboard` | Sent when a Twitch account finishes activating. |
| `web_dashboard_available` | `dashboard` | One time ever, to every registered user. |

### Not sent by SwiftMiner

`discord_linked` and `setup` are SwiftBot's own; `drop_claimed` is retired and
must not be reintroduced — campaign-level completion is the only drop DM.

---

## 5. Campaign DMs versus account DMs

`campaign_id` and `game_artwork_url` together mark a DM as being about a
campaign. Those should read as campaign cards: artwork, game name, campaign name,
then the miner.

A DM with no `campaign_id` is about the account. Those should lead with the
Twitch account/miner instead, so "my account has a problem" is distinguishable
from "something happened with a campaign" at a glance.

---

## 6. Suggested embed structure

Same shape for every production DM:

1. **Title** — what happened. From `issue_kind` where present.
2. **Context** — the affected miner: `miner_display_name`, else `twitch_username`.
3. **Detail** — `affected_game` / `campaign_name` / `recovery_reason`.
4. **Consequence** — only when there is one ("Mining has been paused.").
5. **Primary action** — one button, from `portal_url` + `portal_destination`.

`help_url` is a secondary link, not a second primary button.

---

## 7. Worked example

Subscription-gated campaign, manual reminder from the Pending item:

```json
{
  "message_type": "account_action_required",
  "debug": false,
  "twitch_username": "john",
  "priority_games": ["Cyberpunk 2077"],
  "affected_game": "Cyberpunk 2077",
  "campaign_name": "Phantom Liberty Drops",
  "account_id": "123456",
  "miner_display_name": "John",
  "recovery_reason": "A paid Twitch subscription is required to earn Phantom Liberty Jacket from Phantom Liberty Drops.",
  "portal_url": "https://portal.example.com/app#/campaign/camp%2D1",
  "portal_destination": "campaign",
  "issue_kind": "subscription_required",
  "campaign_id": "camp-1",
  "help_url": "https://swiftminer.app/help/subscription-required-drops/"
}
```

Rendering to:

> **Twitch Subscription Required**
>
> SwiftMiner found something preventing **John** from progressing with a campaign.
>
> **Cyberpunk 2077: Phantom Liberty Drops**
> Requires an active Twitch subscription.
>
> `[View Campaign]`   ·   [Learn more](https://swiftminer.app/help/subscription-required-drops/)

---

## 8. Not yet implemented

Tracked here so the two sides do not diverge. None of these are in the payload
yet, and SwiftBot should not expect them.

These are the remaining items from the DM improvement brief — everything above
this line is done.

- **`welcome_back` → "Mining Resumed"**, gated on a meaningful interruption
  rather than any return. The type name will stay `welcome_back` for
  compatibility; only the rendering and the firing rule change.
- **`connection_restored`** — a new low-priority confirmation after a
  user-initiated reconnect succeeds. Needs a new message type.
- **Unifying the reauth flow.** Three things currently mean "reconnect your
  Twitch account": the automatic `reauth` DM, the manual reminder, and the
  `user.reauth_requested` webhook behind the miner's "Fix Connection" action.
  That webhook does **not** produce a DM log entry, so SwiftMiner cannot tell
  the operator whether anything was delivered.
- **Critical-notification override for Quiet Hours.** Automatic DMs respect
  Quiet Hours; manual sends bypass them. Whether genuinely critical account
  problems should also bypass is deliberately unresolved.
