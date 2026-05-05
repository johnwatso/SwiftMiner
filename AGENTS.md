# SwiftMiner Agent Notes

## Build System

SwiftMiner is **not** a Swift Package. There is no `Package.swift`. Do not run `swift build` or `swift test` — they will not find this project.

The Xcode project is generated from `project.yml` by [XcodeGen](https://github.com/yonaskolb/XcodeGen). Build and test with `xcodebuild`:

```sh
xcodebuild -project SwiftMiner.xcodeproj -scheme SwiftMiner -configuration Debug build
xcodebuild -project SwiftMiner.xcodeproj -scheme SwiftMiner -configuration Debug test
```

Run `xcodegen` after editing `project.yml` to regenerate `SwiftMiner.xcodeproj`.

After `xcodegen` runs, SourceKit may briefly surface stale diagnostics — most often `No such module 'SwiftMinerCore'` in app-target files, or `No such module 'XCTest'` in new test files. These are editor-only and clear once `xcodebuild` has produced fresh module artifacts. Trust `xcodebuild build` / `xcodebuild test` results over SourceKit warnings.

## Versioning

`MARKETING_VERSION` is manually owned by the user. Do not bump it automatically. You may *suggest* a new marketing version when a change would normally warrant one, but wait for explicit user confirmation before editing it.

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

## Info.plist Gotcha: `INFOPLIST_KEY_*` Is Ignored Here

This target sets a custom `INFOPLIST_FILE` (`Sources/SwiftMiner/Info.plist`). When `INFOPLIST_FILE` is set, Xcode **silently ignores** all `INFOPLIST_KEY_*` build settings — they only apply when Info.plist is fully auto-generated. Adding `INFOPLIST_KEY_SUFeedURL` to the `settings:` block will compile and produce no warning, but the key will **not** appear in the built `Info.plist`, breaking Sparkle (and any other consumer that reads via `Bundle.infoDictionary`).

Add Info.plist keys via the xcodegen `info: properties:` block instead — that writes them into `Sources/SwiftMiner/Info.plist` on regen, and `$(VAR)` macros are expanded by the `ProcessInfoPlistFile` build step at build time.

Always confirm new Info.plist keys land in the built bundle:

```sh
/usr/libexec/PlistBuddy -c 'Print <KEY>' ~/Library/Developer/Xcode/DerivedData/SwiftMiner-*/Build/Products/Debug/SwiftMiner.app/Contents/Info.plist
```
