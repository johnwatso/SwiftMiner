# SwiftMiner Safari

SwiftMiner can recover from a Twitch persisted-query hash change without a new app
release. The bundled Safari Web Extension is idle during ordinary browsing and runs
only when SwiftMiner asks it to, from Settings → Advanced → Twitch Compatibility →
**Update via Safari**.

An update is a single session in a single tab:

1. SwiftMiner builds a queue of the pages that issue the operations it needs, and opens
   one Twitch tab whose URL fragment carries that queue.
2. The content script takes the queue, strips the fragment so a reload cannot restart
   the run, and stores the session in `sessionStorage` — per tab, gone when it closes.
3. For each item it waits for that operation's GraphQL request, reads its hash, reports
   it, updates an in-page progress banner, then navigates the same tab to the next page.
4. An operation that does not appear within twenty seconds is marked failed and the
   queue continues, so one missing hash cannot abort the rest.
5. At the end SwiftMiner receives both the hashes found and the operations that failed,
   the banner reports the outcome, and the extension goes idle again.

Without a queue in the fragment or an active session in `sessionStorage`, the content
script returns immediately: no page hook is injected and no traffic is examined.

An observation is saved as an untrusted **candidate**, never an active override.
SwiftMiner tries that candidate through its normal Twitch client. A response that
recognizes the persisted query *and* carries the fields SwiftMiner reads promotes it to
the active override. Anything else retires it and restores the immutable bundled hash.

## Privacy boundary

The extension is limited to `https://www.twitch.tv/drops/*` and
`https://www.twitch.tv/directory/*`. The Drops pages carry `ViewerDropsDashboard` and
`Inventory`; the category directory carries `DirectoryPage_Game`, which upstream has
rotated more often than every other operation combined — four of the eight rotations in
the year to September 2026. Reaching the remaining operation, `AvailableDrops`, would mean
matching channel pages, which is effectively the whole of twitch.tv, so it is left out.

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
operation and hash. Headers, cookies, OAuth values, GraphQL variables, and responses
are never forwarded or stored. Automatic discovery is off by default.

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
   **Update via Safari**. One Twitch tab opens and steps through the queue; a banner
   under the page header reports progress, and the tab is left alone once it finishes.
   On first use, approve the extension's request for access to `twitch.tv`; Safari
   owns this one-time permission and SwiftMiner cannot grant it on your behalf. If
   nothing is reported back, SwiftMiner points directly to the likely missing Safari
   permission.

Safari controls extension enablement and site access, so those steps cannot be
silently performed by SwiftMiner. Safari may require **Allow Unsigned Extensions**
again after it is relaunched.

## Release signing

Release builds use `group.com.swiftminer.shared` so the sandboxed app and extension
share candidates. Shipping therefore requires the App Group to exist for the release
team and to be present in both provisioning profiles. The existing notarized app
release remains the distribution vehicle; this is an embedded Safari Web Extension,
not a separate Safari App Store product.

The manual Advanced setting remains the long-term escape hatch if the extension is
disabled, Safari changes its extension behavior, or future maintainers stop shipping
SwiftMiner updates.
