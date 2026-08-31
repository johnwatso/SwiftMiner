# SwiftMiner Release Runbook

This document outlines the process for building and publishing a new release of SwiftMiner with Sparkle auto-updates.

## Prerequisites

- **Xcode 16+** and **XcodeGen**.
- **Sparkle Signing Key**: The private EdDSA key is required to sign the appcast.
- **GitHub CLI (`gh`)**: (Optional) Used for automated release creation and asset upload.

## 1. Prepare the Build

1. Update the version number in `project.yml`:
   - `MARKETING_VERSION`: The user-facing version (e.g., `1.06`).
   - `CURRENT_PROJECT_VERSION`: The build number (numeric, e.g., `2026032601`).
2. Run `xcodegen` to update the Xcode project:
   ```bash
   xcodegen
   ```

## 2. Generate and Sign the Release

The `scripts/publish_sparkle_release.sh` script automates the build, packaging, and appcast update.

### Environment Variables

- `SPARKLE_PRIVATE_KEY_PATH`: Path to your private `.pem` key file.
- `SWIFTMINER_ROOT`: (Internal) The root of the repository.

### Execution

```bash
export SPARKLE_PRIVATE_KEY_PATH="/path/to/your/private_key.pem"
./scripts/publish_sparkle_release.sh <version> <path_to_app_or_zip> [release_notes_html] [--channel stable|beta]
```

**Example:**
```bash
./scripts/publish_sparkle_release.sh 1.39 ./DerivedData/Build/Products/Release/SwiftMiner.app Documentation/ReleaseNotes/1.39.html --channel stable
```

Curated notes must stay in `Documentation/ReleaseNotes/` before release. ShipHook copies
the supplied page into `docs/release-notes/<version>.html`; using that destination as
the input makes ShipHook's `cp` fail because both paths are identical. The website
builder merges the curated directory with ShipHook's archive and prefers the curated
page when both contain the same version.

## 3. Manual Appcast Signing (Fallback)

If the automated script fails to sign, use the `sign_update` tool directly:

```bash
# Find the tool in DerivedData
SIGN_TOOL=$(find ~/Library/Developer/Xcode/DerivedData -name sign_update | head -n 1)

# Sign the archive
$SIGN_TOOL --ed-key-file /path/to/private_key.pem ./release-artifacts/SwiftMiner-<version>.zip
```

Copy the generated `sparkle:edSignature` and update `Website/public/appcast.xml`.

## 4. Key Rotation (March 2026)

As of March 26, 2026, the Sparkle signing key has been rotated.
- **New Public Key**: `OTycmeGRCsewFd9QUCV93CiC40oE+iiewSfWMptLeLI=`
- **Reason**: Previous key was inaccessible in the headless environment.
- **Impact**: Clients on versions older than `1.05` will need to manually update once if the trust chain is broken, or the new public key must be delivered via an intermediate signed update if possible.

## 5. Deployment

1. **Verify**: Ensure `Website/public/appcast.xml` contains the new version and a valid `sparkle:edSignature`.
2. **Commit**:
   ```bash
   git add project.yml Website/public/appcast.xml Sources/SwiftMiner/Info.plist
   git commit -m "Release v1.05"
   ```
3. **Push**:
   ```bash
   git push origin main
   ```
4. **GitHub Release**: Ensure a GitHub Release exists with the tag `v1.05` and contains the `SwiftMiner-1.05.zip` archive.
