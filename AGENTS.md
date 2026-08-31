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
- **Do not touch `docs/appcast.xml` (or `docs/beta/appcast.xml`).** ShipHook owns these — see warning below. The `Website/public/appcast.xml` / `Website/public/beta/appcast.xml` copies are build output generated from `docs/` by `.github/workflows/deploy-website.yml` at deploy; they are `.gitignore`d and must not be committed.

> [!WARNING]
> **Agents must not update `docs/appcast.xml` / `docs/beta/appcast.xml`.** ShipHook writes to `docs/` (its only known write location), and the deploy workflow copies those files into `Website/public/` when publishing. The appcast advertises updates to every installed copy of the app, and its `sparkle:version` must always match the `CFBundleVersion` of the exact binary at the `<enclosure url>`. If an agent bumps `sparkle:version` on an ordinary dev commit while the enclosure still points at the previously released zip, Sparkle sees a "newer" build, prompts an update, downloads the *same old* binary, and nags users in an endless loop.
>
> `CURRENT_PROJECT_VERSION` in `project.yml` / `project.pbxproj` may be bumped freely on dev commits — but leave the appcast to ShipHook. The **only** time the appcast is edited by hand is the deliberate post-release EdDSA re-signing step the user explicitly asks for (see "Appcast EdDSA signing" below), and even then you only insert the `sparkle:edSignature` for the binary ShipHook already published — never the version/build fields.
- Update release notes for the active marketing version:
  - Author the curated input at `Documentation/ReleaseNotes/<MARKETING_VERSION>.html`.
  - Do not place an unreleased page at `docs/release-notes/<MARKETING_VERSION>.html`:
    that is ShipHook's copy destination, and using it as the input makes ShipHook copy
    the file onto itself and fail after notarization.
  - Run `python3 scripts/build_release_notes.py` to generate the ignored
    `Website/public/release-notes/` pages, index, and sitemap entries.
  - Any visible build references should match the generated build number.
- If the marketing version changes, make sure release-note links and filenames follow the new version.

### Curated release notes and GitHub Releases

The polished, curated release notes are authoritative. ShipHook may create a generic
page from the tip commit message as part of publishing; that output is a transport
fallback, not acceptable final release copy.

- A finished release note should be easy to scan while retaining useful detail:
  group related changes into a small number of outcome-focused sections, lead with
  what improved for the user, and combine closely related implementation details.
  Do not publish a commit dump, a single refactor description, or internal class and
  function names as the primary release story.
- Treat a page as generic ShipHook output when it lacks the normal SwiftMiner version
  title, introduction, and structured sections, or when it mostly repeats the latest
  commit message. `python3 scripts/build_release_notes.py --check` detects this shape.
- Never move the curated input into ShipHook's destination before publishing. Keep it
  at `Documentation/ReleaseNotes/<version>.html`; the website builder overlays it on
  `docs/release-notes/<version>.html`, so the polished page replaces generic ShipHook
  output on the public site without triggering the same-file copy failure.
- After every ShipHook release, run the release-note builder and verify that the
  generated website page for that version exactly matches the curated input. If
  ShipHook committed a generic page under `docs/`, leave the curated input in place;
  it remains the public authority and safely shadows the generated page.
- The matching GitHub Release body should follow the same editorial style and cover
  the same user-visible changes, using concise Markdown headings and bullets. It does
  not need to reproduce every sentence, but it must not be only a commit title or raw
  implementation notes.
- As part of every release completion, and during periodic release-maintenance audits,
  inspect at least the latest stable GitHub Release (and latest beta when applicable)
  with `gh release view`. Confirm its version, body, tag, and attached SwiftMiner zip.
  If the body is generic and the task includes release publishing authority, replace
  it with a Markdown rendering of the curated notes using `gh release edit`; otherwise
  report the mismatch explicitly for the user to approve. Also verify that its linked
  website notes resolve to the curated page.

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
- `docs/appcast.xml`'s `sparkle:version` matches the `CFBundleVersion` of the released binary at the `<enclosure url>` — **not** simply the current working-tree `CURRENT_PROJECT_VERSION` (these differ on any commit made after the last release).
- Release-note links in `docs/appcast.xml` point to existing files.

Before committing changes that touch Sparkle, appcast, release notes, build settings, Info.plist generation, signing/notarization settings, or version metadata, test that Sparkle update configuration still works in the built app. At minimum, build the app and verify the Sparkle Info.plist keys and appcast metadata above before committing.

### Appcast EdDSA signing

Releases are produced by ShipHook, which code-signs/notarizes under a different Apple ID and **does not** have the Sparkle EdDSA private key. As a result, ShipHook-pushed appcast commits (authored by Max Hewett, message prefix `chore(shiphook): update appcast for SwiftMiner ...`) leave the `<enclosure>` with **no** `sparkle:edSignature` attribute, and Sparkle on the client correctly rejects those updates as improperly signed.

After every ShipHook release, the appcast must be re-signed locally before installs can update:

1. Download the released zip from the GitHub Release matching the appcast `enclosure url` and `length`.
2. Run Sparkle's `sign_update <zip>`. The binary is at `~/Library/Developer/Xcode/DerivedData/SwiftMiner-*/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update` after any build of the SparklePublisher scheme. Approve the keychain access prompt.
3. Insert the returned `sparkle:edSignature="…"` attribute into the `<enclosure>` in `docs/appcast.xml` (and `docs/beta/appcast.xml` for beta releases). The deploy workflow copies these into `Website/public/` — do not edit the `Website/public` copies directly, they are overwritten at deploy.
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
