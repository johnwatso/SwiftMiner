# Friend invitations

"Share With a Friend" creates one temporary invitation — an HTTPS link to
`swiftminer.app/setup/` with the Twitch device code inside the URL fragment —
and offers three ways to hand it over. Every path delivers the same link; only
the carrier differs.

| Option | Mechanism |
|---|---|
| **Email Invitation…** | Apple Mail scripting (`html content` on an outgoing message) |
| **Share Invitation…** | `NSSharingServicePicker` — the standard macOS share sheet |
| **Share via SwiftBot…** | Existing SwiftBot DM transport, `friend_invitation` message type |

SwiftMiner never sends anything itself on the first two paths: Mail opens an
unaddressed draft the user reviews and sends, and the share sheet hands off to
whichever destination the user picks.

## What Apple Mail accepts

Checked on macOS Tahoe 26.5.1 against the installed Mail share extension and
Mail's scripting interface.

### Through the share sheet

`MailShareExtension.appex` advertises `NSExtensionActivationSupportsText`,
`…SupportsWebURLWithMaxCount`, and file/image/movie rules — there is no HTML
activation type, and `NSSharingService.canPerform(withItems:)` is false for raw
HTML `Data`.

What the extension does consume:

- **Plain and attributed text** — an `NSAttributedString` arrives as rich text.
  Bold, point sizes, colours, kerning, background colours and links all survive.
- **A URL**, appended to the body as a link.
- **`NSSharingService.subject`**, which fills the Subject field.

What it will not do:

- **Inline images are hoisted out of the flow.** RTFD attachments (an icon, a
  drawn CTA) arrive as attachments *after* all of the text regardless of where
  they sit in the attributed string, so a card layout is not reachable this way.
- **SwiftUI's `ShareLink` drops `subject` and `message` on macOS.** A
  `ShareLink(item:subject:message:)` reaches Mail as an empty subject and a bare
  URL, which is why the share sheet is now driven by `NSSharingServicePicker`
  with a delegate that sets `subject` on the chosen service.

### Through Mail's scripting interface

An outgoing message accepts `html content`, and the compose window is a WebKit
editor that renders it: rounded CTA buttons, tinted panels, type hierarchy and a
remote `<img>` all appear as authored. This is what "Email Invitation…" uses.

Four behaviours matter, and three of them cost a round of debugging each:

1. **Mail only realises a compose window while it has at least one message
   viewer open.** With every window closed — a normal way to leave Mail running
   — the outgoing message is created and Mail comes to the front showing
   nothing, which reads as a crash. A first Apple Event opens a viewer when
   there is none.
2. **Subject, body and visibility all have to be set in the one `make new`.**
   Creating the message with `visible:false` and revealing it afterwards races
   with Mail's own window handling: the window flashes up as "New Message" and
   disappears a second later, leaving an orphaned outgoing message behind. And
   setting `html content` on an already-visible message leaves the body empty.
   Passing `subject`, `html content` and `visible:true` together in the
   properties record avoids both.
3. **A compose window created while Mail is still launching gets torn down.**
   The viewer event runs first and absorbs the startup, with a short settle
   before the compose event.
4. The icon is referenced as `https://swiftminer.app/icon-192.png` rather than an
   embedded `data:` URI, because several mail clients strip data URIs on receipt.

`NSAppleScript` is not thread-safe, and the Apple Event it sends needs a run loop
on the calling thread to receive Mail's reply, so the script runs on the main
actor. Mail is launched first through `NSWorkspace`, which keeps that main-thread
call brief instead of blocking on a cold launch.

Bringing Mail forward takes three steps, because activating another app is
cooperative on modern macOS and the compose window is created after the
activation:

1. `NSApp.yieldActivation(toApplicationWithBundleIdentifier:)` before launching,
   so macOS lets SwiftMiner hand the front to Mail at all.
2. An `activate` at the end of the compose script, once the draft window exists.
3. A plain `NSRunningApplication.activate()` afterwards — deliberately *not*
   `.activateAllWindows`, which raises Mail's inbox over the new draft.

Apple Events from a hardened-runtime app need the
`com.apple.security.automation.apple-events` entitlement (in
`Sources/SwiftMiner/SwiftMiner.entitlements`) and `NSAppleEventsUsageDescription`
in `Info.plist`. Verified working from a hardened, entitled build. macOS asks the
user for Automation permission the first time; a refusal surfaces as AppleScript
error `-1743` and `MailInvitationComposer` turns it into a plain instruction
rather than a silent failure.

**Release signing note:** the entitlement must survive ShipHook's signing. If a
release build is re-signed without it, "Email Invitation…" fails with the
Automation message while the other two options keep working.

## What each destination receives

- **Email Invitation…** — subject `<inviter> invited you to SwiftMiner`, and the
  branded HTML card: app icon, `INVITATION` label, headline, inviter line, purple
  "Connect to SwiftMiner" button, the credentials reassurance, the live expiry,
  and a `swiftminer.app` footer. The raw link follows in small text so the mail
  still works where the button does not.
- **Share Invitation… → Mail** — subject, the formatted body (headline, inviter
  line, reassurance, expiry) and the invitation URL appended as a link.
- **Share Invitation… → Messages** — the URL only. The macOS Messages share
  extension discards any accompanying text item, plain or attributed. The link
  unfurls into a native rich card from the setup page's Open Graph metadata.
- **Share Invitation… → AirDrop / Copy / Notes / Reminders** — the URL, with the
  text where the destination takes it.
- **Share via SwiftBot…** — a `friend_invitation` DM carrying
  `activation_url` (the setup link), `activation_expires_in_minutes` and
  `inviter_display_name`. No Twitch device code and no `twitch.tv/activate` URL.

The share sheet itself shows a `Connect to SwiftMiner · swiftminer.app` link
preview, fetched by LinkPresentation from the page metadata.

## Hosted preview metadata

`Website/public/setup/index.html` carries Open Graph and Twitter cards pointing
at `https://swiftminer.app/assets/share/swiftminer-invitation.png` (generic
1200×630 artwork, no per-inviter generation). `LPMetadataProvider` resolves the
title, description, image and icon for the invitation URL.

The invitation payload lives in the fragment, which is never sent to the host, so
a server-rendered inviter-specific card is not possible on a static site. The
page rewrites its own title and description after decoding the invitation, which
covers the browser; crawlers see the generic card. That affects only the unfurled
preview — the Mail draft, the SwiftBot DM and the page itself all name the
inviter.

## Explaining it to the recipient

`swiftminer.app/help/invited-to-swiftminer/` is written for the person receiving
the invitation rather than the operator: what the token actually is, what the
inviter can and cannot see, the reasons to decline (including "do you trust this
person and their Mac?"), what SwiftMiner cannot do, and how to revoke the grant
at Twitch without the operator's help.

It is linked from the setup page above the expiry line, from inside the Mail
invitation's reassurance panel, and as `help_url` on the SwiftBot
`friend_invitation` DM.

Both call-to-action buttons say "Connect to SwiftMiner" but go to different
places — the mail's opens `swiftminer.app/setup/`, the page's opens
`twitch.tv/activate` — so each now says where it lands underneath. A button that
claims Twitch and opens somewhere else is exactly what a recipient checking the
link would read as phishing.
The page is deliberately two-sided — an invitation that only argues for itself is
the kind recipients are right to distrust.

## Invitation integrity

The payload is `v1.<expiry>.<base64url(deviceCode)>.<base64url(inviter)>`. It is
encoded, not signed: anyone holding an invitation can re-encode it with a
different inviter name before forwarding it.

The device code is the only capability in the link, and it cannot be forged —
it comes from Twitch through the inviter's own SwiftMiner, and connecting always
attaches the account to that instance. So tampering cannot redirect an account
anywhere; it can only mislabel who is asking. Signing the payload would need a
key the static setup page could verify, which a JavaScript-only page cannot hold
secretly. Treat the inviter name as a display hint, not an authenticated claim.
