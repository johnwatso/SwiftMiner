# SwiftMiner Agent Notes

## Versioning

`MARKETING_VERSION` is manually owned by the user. Do not invent or bump it unless the user explicitly asks.

`CURRENT_PROJECT_VERSION` is timestamp-based and should be updated whenever making or preparing code, project, appcast, or release-note changes.

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

## Project Generation

`project.yml` is the source config for generated Xcode project settings. If a package, dependency, version, build setting, or Sparkle Info.plist setting changes, keep `project.yml` and `SwiftMiner.xcodeproj/project.pbxproj` aligned.

Avoid committing unrelated XcodeGen metadata drift. In particular, do not let package/project regeneration silently roll back:

- `MARKETING_VERSION`
- `CURRENT_PROJECT_VERSION`
- Sparkle appcast/public-key Info.plist settings
- existing scheme metadata or build settings unrelated to the requested change
