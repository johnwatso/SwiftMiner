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
| `inviter_display_name` | string? | Who is inviting the recipient, already formatted as `@name`. Only on `friend_invitation`. |
| `activation_expires_at` | string? | Absolute expiry as an **ISO 8601 string**, so SwiftBot can render Discord's `<t:UNIX:R>` live countdown instead of a minute count frozen at send time. |

### Dates on the wire

`activation_expires_at` is an ISO 8601 string. SwiftBot decodes it with a plain
`try` against `String`, so a numeric date does not merely lose the countdown —
it fails the decode of the entire payload and the DM is dropped. SwiftMiner
sends it through `RestSwiftBotConnectionService.dmEncoder`, which is pinned to
`.iso8601` and covered by a test.

Senders should include `activation_expires_in_minutes` as well; SwiftBot prefers
the absolute instant and falls back to the minute count on older builds.

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

### Invitation

| Type | `portal_destination` | Key fields |
|---|---|---|
| `friend_invitation` | none | `activation_url`, `activation_expires_in_minutes`, `inviter_display_name` |

Sent by hand from **Add a Miner › Share With a Friend › Share via SwiftBot…**, to
a Discord member the operator picks. Unlike every other DM this one is about the
*recipient's* Twitch account, which they have not connected yet — so there is no
miner to name and no portal to link.

`activation_url` is a `swiftminer.app/setup/` link that carries the Twitch device
code inside its URL fragment. Render it as the one primary button ("Connect to
SwiftMiner"). Do not surface a Twitch activation code or a `twitch.tv/activate`
URL: the setup page owns that fallback.

Suggested embed: title "You've been invited to SwiftMiner", body
"`inviter_display_name` has invited you to connect your Twitch account.", the
reassurance that they sign in directly with Twitch and their credentials are
never shared with the inviter, and the expiry from
`activation_expires_in_minutes`.

**Status: implemented on both sides.** SwiftBot renders the invitation as its
own embed, with the setup link as the primary button and `help_url` as a
secondary "What is SwiftMiner?" — the only DM where a help link appears without
a portal button, because a recipient who cannot open the invitation is exactly
the one who needs to know what they were sent.

Two behaviours are specific to this type. SwiftBot's per-type notification
preferences do not apply: they describe ongoing mining alerts for an existing
miner, and none of them should silence a one-off invitation an operator sent by
hand. And a `friend_invitation` never falls back to advertising the operator's
dashboard, which the recipient cannot sign in to.

`inviter_display_name` is a display hint. The invitation payload is encoded, not
signed, so it must not be used for any authorisation decision.

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
