# SwiftMiner Safari

SwiftMiner can recover from a Twitch persisted-query hash change without a new app
release. Settings → Advanced → Twitch Compatibility exposes two paths:

- paste a 64-character hash for one known operation; or
- enable the bundled Safari Web Extension and let it observe hashes used by Twitch's
  own Drops pages.

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

The Debug extension deliberately uses the containing app's preferences domain and
does not require the production App Group entitlement. That keeps local development
compatible with Xcode's ad-hoc **Sign to Run Locally** identity.

1. Generate and build the project:

   ```sh
   xcodegen
   xcodebuild -project SwiftMiner.xcodeproj -scheme SwiftMiner -configuration Debug build
   ```

2. Launch the built `SwiftMiner.app` once so macOS registers its embedded extension.
3. In Safari, enable **Develop → Allow Unsigned Extensions**. Safari may require you
   to enable its Develop menu first in Settings → Advanced.
4. Open Safari Settings → Extensions and enable **SwiftMiner Query Hash Discovery**.
5. In SwiftMiner Settings → Advanced, enable **Discover query hashes in Safari**,
   then open Twitch Drops from the same section and reload the page.

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
