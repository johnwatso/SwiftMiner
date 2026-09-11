# SwiftMiner Safari

SwiftMiner can recover from a Twitch persisted-query hash change without a new app
release. Settings → Advanced → Twitch Compatibility exposes two paths:

- paste a 64-character hash for one known operation; or
- choose **Check Hash Values in Safari** and let the bundled Safari Web Extension
  observe hashes used by Twitch's own Campaigns and Inventory pages.

Both paths save an untrusted **candidate**, not an active override. SwiftMiner tries
that candidate through its normal Twitch client. A response that recognizes the
persisted query promotes it to the active override. `PersistedQueryNotFound` removes
it and immediately retries the immutable hash bundled with the app. Reset to Bundled
is always available and neither path requires an app restart.

## Privacy boundary

The extension is intentionally limited to `https://www.twitch.tv/drops/*`. Its page
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
5. In SwiftMiner Settings → Advanced, choose **Check Hash Values in Safari**.
   SwiftMiner enables discovery and opens Twitch Campaigns and Inventory in Safari;
   the extension collects supported hashes those pages use without manual entry.
   On first use, approve the extension's request for access to `twitch.tv`; Safari
   owns this one-time permission and SwiftMiner cannot grant it on your behalf.

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
