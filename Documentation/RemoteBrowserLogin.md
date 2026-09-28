# Remote browser login

## Status

SwiftMiner now exposes the host-local half of this design for a fresh installation: its first
account signs in on Twitch's website inside an app-owned persistent `WKWebView`, and becomes
the full-access Operator only after SwiftMiner validates the Twitch identity, campaign
dashboard, inventory, integrity token and scoped SDK cookie. The mining client reuses the
captured integrity token and renews it from the SDK seed after expiry.

The cross-platform remote-helper half remains experimental and is not exposed in the WebUI.
Its implementation slice defines the credential model, validates helper payloads, and owns
short-lived one-time handoffs, but does not advertise a remote browser login until the native
helper and public WebUI path have passed live end-to-end testing.

Existing Android-client and TV-client accounts are not migrated or replaced by this work.
They continue to use the client and token that issued their current session.

## Why a helper is required for remote browser accounts

Twitch's sign-in and browser SDK state belong to the Twitch origin. A page in SwiftMiner's
WebUI cannot read that state from an iframe or popup, and Twitch does not allow its login page
to be embedded. A native helper can open a separate Chrome profile on the account owner's
computer, let Twitch handle the password and two-factor prompts, and hand only the resulting
session material to the SwiftMiner host.

The account owner may be remote from the Mac running SwiftMiner. The helper therefore talks
to the host over the public WebUI origin; it is not required to run on the host Mac.

## Intended flow

1. A signed-in WebUI user asks SwiftMiner to connect a Twitch account.
2. SwiftMiner creates a 256-bit, single-use capability bound to that WebUI principal and the
   requested account operation. It stores only the capability's SHA-256 digest and expires it
   after ten minutes.
3. The helper confirms the exact SwiftMiner HTTPS origin, launches an owned temporary Chrome
   profile, and the user signs in on Twitch itself.
4. The helper captures one successful protected campaign request and its matching integrity
   response. It uploads a strict, versioned bundle containing the OAuth token, the allowlisted
   request identity, and only the scoped `KP_UIDz-ssn` SDK cookie.
5. The host validates the Twitch identity, inventory, and campaign catalogue before changing
   any account. It then obtains and validates a host-issued replacement context, saves the
   OAuth and browser material together, consumes the capability, and attaches the miner.
6. The helper closes Chrome and removes its profile. The host renews the integrity context
   shortly before Twitch's supplied expiry; the remote user's computer can be turned off.

## Security boundaries

- Remote handoff is HTTPS-only. Plain HTTP is allowed only for an explicitly local loopback
  development flow, never for a remote account owner.
- A dashboard session and CSRF token create or cancel a handoff. There is no globally open
  "accept the next account" switch.
- The raw capability is returned once, sent in the Authorization header, and never placed in a
  URL, log, database, status response, or audit message.
- Uploads are limited to 64 KiB and accept an exact schema, Twitch's fixed web client ID,
  printable header values, and one named SDK cookie. Redirects and ambient cookies are not
  part of the helper protocol.
- Validation and persistence are staged. A malformed bundle, wrong account, Twitch failure,
  or storage failure leaves every existing account and running miner unchanged.
- Browser session material lives with the account's OAuth token. It must not be split across
  UserDefaults or another best-effort sidecar.
- Existing accounts are never silently converted to browser login. Reauthentication is an
  explicit, account-scoped operation.

## Work still required before release

- Prove the host-local Operator flow through a fresh login, integrity renewal, app restart,
  progress and claim run; then exercise expiry, outage, revocation and account switching.
- Add explicit browser-renewal health and relogin recovery states to the native UI.
- Connect remote helper imports to the account ownership and miner-attachment transaction.
- Build, sign, and publish native helper binaries for macOS, Windows, and Linux.
- Add the WebUI start/status/recovery experience and update the security disclosures.
- Complete platform smoke tests and an independent security review before enabling the feature.

## Prior art

The flow is informed by TwitchDropsMiner 2.0.0's MIT-licensed desktop helper and server-renewal
work. SwiftMiner uses a principal-bound, one-time capability rather than copying its globally
reachable admission switch, and keeps the implementation native to SwiftMiner's existing Xcode
project and storage model.
