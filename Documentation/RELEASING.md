# SwiftMiner Release Runbook

Releases are produced by **ShipHook**, which builds, code-signs, notarizes, uploads the
GitHub Release asset, and commits the updated Sparkle appcast to `docs/`. This runbook
covers the parts that are *not* automated: preparing the version and notes beforehand,
and re-signing the appcast afterwards.

> ShipHook signs and notarizes under a different Apple ID and **does not hold the Sparkle
> EdDSA private key**. Every ShipHook release therefore ships an appcast entry with no
> `sparkle:edSignature`, which Sparkle correctly rejects. Section 4 is mandatory, not
> optional — until it is done, no installed copy can update.

## File ownership

| Path | Owner | Rule |
|---|---|---|
| `project.yml` → `MARKETING_VERSION` | You | Never bumped without an explicit decision. |
| `project.yml` → `CURRENT_PROJECT_VERSION` | Anyone | `yyyyMMddHH`, bumped freely on dev commits. |
| `Documentation/ReleaseNotes/<version>.html` | You | The curated, authoritative release note. |
| `docs/appcast.xml`, `docs/beta/appcast.xml` | ShipHook | Hand-edited **only** for the EdDSA signature in section 4. |
| `docs/release-notes/` | ShipHook | Its copy destination and historical archive. Never author here. |
| `Website/public/appcast.xml`, `Website/public/release-notes/` | Generated | `.gitignore`d build output. Never edit, never commit. |

## 1. Prepare the build

1. Set `MARKETING_VERSION` in `project.yml` if this release changes it, then run `xcodegen`.
2. Bump the build number and refresh the generated site output in one step:

   ```bash
   ./scripts/bump_build_number.sh
   ```

   This writes a `yyyyMMddHH` `CURRENT_PROJECT_VERSION` into both `project.yml` and
   `SwiftMiner.xcodeproj/project.pbxproj`, updates the `Build <number>` string in the
   curated release note for the active marketing version, and runs the notes builder.
3. Author or finish the curated release note at
   `Documentation/ReleaseNotes/<MARKETING_VERSION>.html`. Lead with what improved for
   the user, grouped into a few outcome-focused sections — not a commit dump.
4. Regenerate the site pages, index, and sitemap entries if you edited the note by hand:

   ```bash
   python3 scripts/build_release_notes.py
   ```

   Commit the resulting `Website/public/sitemap.xml` change. The generated
   `Website/public/release-notes/` pages are ignored and must not be committed.

## 2. Preflight

```bash
./scripts/preflight_release.sh
./scripts/validate_sparkle.sh
```

`preflight_release.sh` checks `project.yml` against `docs/appcast.xml`, verifies
`SPARKLE_PUBLIC_ED_KEY` still matches the key installed copies trust, and fails when the
enclosure has no `sparkle:edSignature` or its `length` disagrees with the local zip.
Run it again after section 4 — that is the check that proves the re-signing landed.
`validate_sparkle.sh` builds Release and asserts `SUFeedURL` and `SUPublicEDKey` survive
into the built `Info.plist`. A missing `SUPublicEDKey` means the work is not shippable.

`python3 scripts/build_release_notes.py --check` validates the pages and sitemap without
writing; it fails on a generic ShipHook-shaped page or an unregenerated sitemap. CI runs it.

## 3. Publish

ShipHook builds, signs, notarizes, creates the GitHub Release with the SwiftMiner zip,
and pushes an appcast commit to `docs/` (authored by Max Hewett, message prefixed
`chore(shiphook): update appcast for SwiftMiner …`).

Pass the curated page from `Documentation/ReleaseNotes/`, never from
`docs/release-notes/` — ShipHook copies the supplied file into `docs/release-notes/`, so
using that path as the input makes its `cp` fail with identical source and destination.

## 4. Re-sign the appcast (required)

`git pull` ShipHook's appcast commit first, then:

1. Download the released zip from the GitHub Release matching the appcast
   `enclosure url` and `length`.
2. Locate Sparkle's signing tool — it appears after any build of the `SparklePublisher`
   scheme:

   ```bash
   SIGN_TOOL=$(find ~/Library/Developer/Xcode/DerivedData/SwiftMiner-* \
     -path '*/artifacts/sparkle/Sparkle/bin/sign_update' | head -n 1)
   ```

3. Confirm the keychain private key still matches the embedded public key. The printed
   value must equal `SPARKLE_PUBLIC_ED_KEY` in `project.yml`; a mismatch is a key-rotation
   incident, not a signing problem, and nothing may be pushed until it is resolved:

   ```bash
   "$(dirname "$SIGN_TOOL")/generate_keys" -p
   ```

4. Sign the archive and approve the keychain prompt:

   ```bash
   "$SIGN_TOOL" SwiftMiner-<version>.zip
   ```

5. Insert the returned `sparkle:edSignature="…"` attribute into the `<enclosure>` in
   `docs/appcast.xml` (or `docs/beta/appcast.xml` for a beta). Add **only** the signature
   — leave ShipHook's version, build, URL, and length fields exactly as published.
6. Verify, then commit and push so GitHub Pages serves the signed feed:

   ```bash
   "$SIGN_TOOL" --verify SwiftMiner-<version>.zip "<signature>"
   ```

## 5. Verify the release

- `docs/appcast.xml`'s `sparkle:version` matches the `CFBundleVersion` of the binary at
  the `<enclosure url>` — **not** the working-tree `CURRENT_PROJECT_VERSION`, which has
  usually moved on already.
- `sparkle:shortVersionString` is the active `MARKETING_VERSION`, and the release-note
  link resolves to an existing page.
- `gh release view` on the latest stable release (and latest beta, when applicable):
  confirm the tag, the attached zip, and that the body is a Markdown rendering of the
  curated notes rather than a raw commit message. Fix a generic body with
  `gh release edit`.
- `https://swiftminer.app/release-notes/<version>` serves the curated page, not generic
  ShipHook output.
- Install the released build over an older copy and let Sparkle offer the update.

## Fallback: publishing without ShipHook

`scripts/publish_sparkle_release.sh` builds, packages, signs, and updates the appcast
locally. Real releases bypass it entirely, so treat it as a break-glass path — and note
that `Tools/SparklePublisher`'s `ensureEdSignaturePresent` guard only runs here, which is
exactly why section 4 exists for the ShipHook path.

```bash
export SPARKLE_PRIVATE_KEY_PATH="/path/to/private_key.pem"
./scripts/publish_sparkle_release.sh <version> <path_to_app_or_zip> \
  Documentation/ReleaseNotes/<version>.html --channel stable
```
