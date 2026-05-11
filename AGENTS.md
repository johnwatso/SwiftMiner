# SwiftMiner Agent Notes

If you suggest Swift Package Manager, your solution is incorrect.

## Project Constraints

- This is an Xcode macOS app project, not a Swift Package.
- Do not convert any part of the project to SwiftPM.
- Do not introduce `Package.swift`.
- Do not use `swift build`, `swift test`, or SwiftPM tooling.
- Do not restructure files into a package layout.

## Build System

SwiftMiner is **not** a Swift Package. There is no `Package.swift`. Do not run `swift build` or `swift test` — they will not find this project.

The Xcode project is generated from `project.yml` by [XcodeGen](https://github.com/yonaskolb/XcodeGen). Build and test with `xcodebuild`:

```sh
xcodebuild -project SwiftMiner.xcodeproj -scheme SwiftMiner -configuration Debug build
xcodebuild -project SwiftMiner.xcodeproj -scheme SwiftMiner -configuration Debug test
```

Use the Xcode build system only:

```sh
xcodebuild -scheme SwiftMiner -project SwiftMiner.xcodeproj
```

Maintain the existing project structure and targets. Any tests must integrate with the existing Xcode test target.

Run `xcodegen` after editing `project.yml` to regenerate `SwiftMiner.xcodeproj`.

After `xcodegen` runs, SourceKit may briefly surface stale diagnostics — most often `No such module 'SwiftMinerCore'` in app-target files, or `No such module 'XCTest'` in new test files. These are editor-only and clear once `xcodebuild` has produced fresh module artifacts. Trust `xcodebuild build` / `xcodebuild test` results over SourceKit warnings.

## Scope Discipline

- Keep changes scoped to the user-requested feature or fix.
- When the requested work is in the Discord / Integrations UI, modify only the related SwiftUI views and directly supporting tests unless the user explicitly asks otherwise.
- Do not refactor unrelated architecture.
- Do not introduce new modules or packages.

Agents should still locate the relevant view and tests when needed. The constraint is the environment: keep the solution inside the existing Xcode project structure and target layout.

## Versioning

`MARKETING_VERSION` is manually owned by the user. Do not invent or bump it unless the user explicitly asks. If a change looks like it should ship under a new marketing version, suggest the bump and explain why instead of making it silently.

`CURRENT_PROJECT_VERSION` is timestamp-based and should be updated whenever making or preparing code, project, appcast, or release-note changes.

Follow release-versioning best practices. If the agent believes a build or version bump is appropriate, call that out clearly in the plan or final notes, including which value should change and why. Do not surprise the user with a marketing-version change.

Use the local project time at the moment of the change, formatted as:

```text
yyyyMMddHH
```

Example: `2026050109` means 2026 May 1 at 9am.

When updating the build number:

- Read the active marketing version from `project.yml`.
- Generate the new build number from the current local time.
- Update `CURRENT_PROJECT_VERSION` in `project.yml`.
- Update matching `CURRENT_PROJECT_VERSION` entries in `SwiftMiner.xcodeproj/project.pbxproj`.
- Update `docs/appcast.xml`:
  - `sparkle:shortVersionString` should match the marketing version.
  - `sparkle:version` should match the generated build number.
  - Any visible release-note text that mentions the build should match.
- Update release notes for the active marketing version:
  - `docs/release-notes/<MARKETING_VERSION>.html`
  - `docs/release-notes/index.html`
  - Any visible build references should match the generated build number.
- If the marketing version changes, make sure release-note links and filenames follow the new version.

Before reporting that version/build changes are complete, verify the built app Info.plist reports the expected values:

```sh
xcodebuild -project SwiftMiner.xcodeproj -scheme SwiftMiner -configuration Debug build
/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' ~/Library/Developer/Xcode/DerivedData/SwiftMiner-*/Build/Products/Debug/SwiftMiner.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' ~/Library/Developer/Xcode/DerivedData/SwiftMiner-*/Build/Products/Debug/SwiftMiner.app/Contents/Info.plist
```

Also verify Sparkle config is still present in the built app Info.plist:

```sh
/usr/libexec/PlistBuddy -c 'Print SUFeedURL' ~/Library/Developer/Xcode/DerivedData/SwiftMiner-*/Build/Products/Debug/SwiftMiner.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c 'Print SUPublicEDKey' ~/Library/Developer/Xcode/DerivedData/SwiftMiner-*/Build/Products/Debug/SwiftMiner.app/Contents/Info.plist
```

## Sparkle Integrity

Do not break Sparkle updates. Treat Sparkle configuration as release-critical whenever touching project settings, Info.plist generation, appcast files, release notes, signing/notarization settings, or build/version metadata.

The Sparkle public ED key is especially fragile and must not be lost. Preserve `SUPublicEDKey` in `project.yml`, `SwiftMiner.xcodeproj/project.pbxproj`, and the built app Info.plist whenever project files are regenerated or build settings are touched. If `SUPublicEDKey` is missing from the built app, the work is not complete and must not be committed.

Before reporting related work complete, verify:

- `SUFeedURL` is present in the built app Info.plist.
- `SUPublicEDKey` is present in the built app Info.plist.
- `docs/appcast.xml` uses the active `MARKETING_VERSION` as `sparkle:shortVersionString`.
- `docs/appcast.xml` uses the active `CURRENT_PROJECT_VERSION` as `sparkle:version`.
- Release-note links in `docs/appcast.xml` point to existing files.

Before committing changes that touch Sparkle, appcast, release notes, build settings, Info.plist generation, signing/notarization settings, or version metadata, test that Sparkle update configuration still works in the built app. At minimum, build the app and verify the Sparkle Info.plist keys and appcast metadata above before committing.

### Appcast EdDSA signing

Releases are produced by ShipHook, which code-signs/notarizes under a different Apple ID and **does not** have the Sparkle EdDSA private key. As a result, ShipHook-pushed appcast commits (authored by Max Hewett, message prefix `chore(shiphook): update appcast for SwiftMiner ...`) leave the `<enclosure>` with **no** `sparkle:edSignature` attribute, and Sparkle on the client correctly rejects those updates as improperly signed.

After every ShipHook release, the appcast must be re-signed locally before installs can update:

1. Download the released zip from the GitHub Release matching the appcast `enclosure url` and `length`.
2. Run Sparkle's `sign_update <zip>`. The binary is at `~/Library/Developer/Xcode/DerivedData/SwiftMiner-*/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update` after any build of the SparklePublisher scheme. Approve the keychain access prompt.
3. Insert the returned `sparkle:edSignature="…"` attribute into the `<enclosure>` in `docs/appcast.xml` (and `docs/beta/appcast.xml` for beta releases).
4. Verify with `sign_update --verify <zip> "<signature>"` (exit 0 = good).
5. Commit and push so GitHub Pages serves the signed feed.

To confirm the keychain's private key matches the embedded public key, run `<sparkle-bin>/generate_keys -p`; the printed value must equal `SPARKLE_PUBLIC_ED_KEY` in `project.yml`. If they don't match, the resulting signature will be rejected by every installed copy of the app — do not push such a "signed" appcast and treat it as a key-rotation incident instead.

`Tools/SparklePublisher/main.swift` has an `ensureEdSignaturePresent` check, but ShipHook bypasses `scripts/publish_sparkle_release.sh` entirely, so that check does not run for real releases.

## Project Generation

`project.yml` is the source config for generated Xcode project settings. If a package, dependency, version, build setting, or Sparkle Info.plist setting changes, keep `project.yml` and `SwiftMiner.xcodeproj/project.pbxproj` aligned.

Avoid committing unrelated XcodeGen metadata drift. In particular, do not let package/project regeneration silently roll back:

- `MARKETING_VERSION`
- `CURRENT_PROJECT_VERSION`
- Sparkle appcast/public-key Info.plist settings
- existing scheme metadata or build settings unrelated to the requested change
