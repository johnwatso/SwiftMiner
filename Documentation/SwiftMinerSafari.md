# SwiftMiner Safari

SwiftMiner can recover from a Twitch persisted-query hash change without a new app
release. The bundled Safari Web Extension is idle during ordinary browsing and runs
only when SwiftMiner asks it to, from Settings → Advanced → Twitch Compatibility →
**Update via Safari**.

An update is a single session in a single tab:

1. SwiftMiner reads the current operation/hash pairs from TwitchDropsMiner's public
   `constants.py`, builds a queue of the Twitch pages that can issue those operations,
   and opens one Twitch tab whose URL fragment carries the queue and validated 64-hex
   fallback values. No Twitch account data is sent to GitHub.
2. The content script takes the queue, strips the fragment so a reload cannot restart
   the run, and stores the session in `sessionStorage` — per tab, gone when it closes.
3. The network hook is installed at document start, before Twitch's startup requests,
   and buffers every requested operation seen on that page. This matters on the campaigns
   page, where Twitch sends multiple useful requests together.
4. For each item it reads the buffered hash, reports it, and updates a floating glass
   progress panel. If Twitch already issued a later operation on the current page, the
   runner consumes that buffered result instead of loading its otherwise-required page.
   Only operations still unseen navigate the same tab to their target page. The browser
   cannot passively reproduce the mining client's `Inventory` document or a campaign
   detail request that requires a click, so those use the exact TDM catalog pair directly.
   Other operations prefer the browser observation and use the catalog only if the page
   no longer issues them.
5. An operation that does not appear within twenty seconds and has no catalog fallback is
   marked failed; the queue continues, so one missing hash cannot abort the rest.
6. At the end SwiftMiner receives both the hashes found and the operations that failed,
   the banner reports the outcome, and the extension goes idle again.

Without a queue in the fragment or an active session in `sessionStorage`, the content
script returns immediately: no page hook is injected and no traffic is examined.

An observation is saved as an untrusted **candidate**, never an active override.
SwiftMiner tries that candidate through its normal Twitch client. A response that
recognizes the persisted query *and* carries the fields SwiftMiner reads promotes it to
the active override. Anything else retires it and restores the immutable bundled hash.
The extension records the observation but does not queue the same rejected value again;
an explicit manual re-check can deliberately give it another attempt.

## Privacy boundary

The extension has permission for `https://www.twitch.tv/*` because one of the five
repeat rotators, `AvailableDrops`, is issued only on a channel page. SwiftMiner uses the
login of a live channel it is already checking; it never chooses an unrelated channel or
reads the page to discover one. The other targeted operations are `ViewerDropsDashboard`,
`Inventory`, `DropCampaignDetails`, and `DirectoryPage_Game`; as described above, the
browser cannot passively reproduce every one of those client documents.

That host permission does not make the extension a continuous observer. On every Twitch
page, the content script validates a SwiftMiner-created, same-origin queue before doing
anything. Without that queue in the URL fragment or the same tab's active `sessionStorage`,
it returns before installing the network hook. The queue accepts only those five operations
and the specific Drops, category, and channel paths SwiftMiner can generate.

Its page
hook examines only POST bodies sent to `https://gql.twitch.tv/gql`, allow-lists the
same operations SwiftMiner knows, and sends only:

```json
{
  "operationName": "ViewerDropsDashboard",
  "sha256Hash": "…64 lowercase hexadecimal characters…"
}
```

The content script, background worker, and native handler independently validate the
operation and hash. Headers, cookies, OAuth values, GraphQL variables, responses, and
channel page contents are never forwarded or stored. Automatic discovery is off by default.
Twitch currently uses two different persisted documents named `Inventory`; the hook
checks the non-sensitive `fetchRewardCampaigns` boolean locally and ignores the
incompatible sibling. That boolean never leaves the page world. SwiftMiner supplies the
correct mining-client Inventory pair from TDM's public catalog instead, and still runs it
through the same candidate validation before adoption.

## Test an unsigned Debug build locally

Safari requires the Debug extension to run in its sandbox. App Groups cannot be
attached to Xcode's ad-hoc **Sign to Run Locally** identity, so local builds pass the
same allow-listed operation/hash pair to the running SwiftMiner app with a local
notification. Release builds use the signed App Group described below.

1. Generate and build the project:

   ```sh
   xcodegen
   xcodebuild -project SwiftMiner.xcodeproj -scheme SwiftMiner -configuration Debug build
   ```

2. Launch the built `SwiftMiner.app` once so macOS registers its embedded extension.
3. In Safari, enable **Develop → Allow Unsigned Extensions**. Safari may require you
   to enable its Develop menu first in Settings → Advanced.
4. Open Safari Settings → Extensions and enable **SwiftMiner Query Hash Discovery**.
5. In SwiftMiner Settings → Advanced → Twitch Compatibility, choose
   **Update via Safari**. One Twitch tab opens and steps through the queue; a floating
   glass panel reports progress, and the tab is left alone once it finishes.
   On first use, approve the extension's request for access to `twitch.tv`; Safari
   owns this one-time permission and SwiftMiner cannot grant it on your behalf. If
   nothing is reported back, SwiftMiner points directly to the likely missing Safari
   permission.

Safari controls extension enablement and site access, so those steps cannot be
silently performed by SwiftMiner. Safari may require **Allow Unsigned Extensions**
again after it is relaunched.

## Release signing

Release builds use the macOS-only, Team-ID-prefixed group
`FHXMYC956U.com.swiftminer.shared` so the sandboxed app and extension share candidates.
Unlike a provisioned `group.` identifier, this form does not require provisioning
profiles; macOS grants access when both processes have the entitlement and are signed
by team `FHXMYC956U`. This keeps the Developer ID archive compatible with ShipHook's
manual signer. The existing notarized app release remains the distribution vehicle;
this is an embedded Safari Web Extension, not a separate Safari App Store product.

The manual Advanced setting remains the long-term escape hatch if the extension is
disabled, Safari changes its extension behavior, or future maintainers stop shipping
SwiftMiner updates.
