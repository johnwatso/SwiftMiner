#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/SwiftMiner.xcodeproj"
SCHEME="${SWIFTMINER_SCHEME:-SwiftMiner}"
CONFIGURATION="${SWIFTMINER_CONFIGURATION:-Debug}"
# ShipHook writes the source feed under docs/. Website/public is deployment
# output and is intentionally not used for release validation.
APPCAST="$ROOT_DIR/docs/appcast.xml"
PROJECT_YML="$ROOT_DIR/project.yml"
EXPECTED_SPARKLE_PUBLIC_KEY="rxaJsfCpTKtpqRubSfkJwKnztT5S8RHsdAueuT+jKck="

fail() {
    echo "error: $*" >&2
    exit 1
}

extract_project_value() {
    local key="$1"
    sed -nE "s/^[[:space:]]*$key:[[:space:]]*\"?([^\"]+)\"?[[:space:]]*$/\\1/p" "$PROJECT_YML" | head -n 1
}

MARKETING_VERSION="$(extract_project_value MARKETING_VERSION)"
CURRENT_PROJECT_VERSION="$(extract_project_value CURRENT_PROJECT_VERSION)"
SPARKLE_PUBLIC_ED_KEY="$(extract_project_value SPARKLE_PUBLIC_ED_KEY)"

[[ -n "$MARKETING_VERSION" ]] || fail "MARKETING_VERSION missing from project.yml"
[[ -n "$CURRENT_PROJECT_VERSION" ]] || fail "CURRENT_PROJECT_VERSION missing from project.yml"
[[ "$SPARKLE_PUBLIC_ED_KEY" == "$EXPECTED_SPARKLE_PUBLIC_KEY" ]] || fail "SPARKLE_PUBLIC_ED_KEY does not match the expected Sparkle EdDSA public key"
[[ -f "$APPCAST" ]] || fail "docs/appcast.xml missing"

APPCAST_SHORT_VERSION="$(xmllint --xpath 'string(//*[local-name()="shortVersionString"])' "$APPCAST" 2>/dev/null || true)"
APPCAST_BUILD_VERSION="$(xmllint --xpath 'string(//*[local-name()="version"])' "$APPCAST" 2>/dev/null || true)"
ENCLOSURE_URL="$(xmllint --xpath 'string(//enclosure/@url)' "$APPCAST" 2>/dev/null || true)"
ENCLOSURE_SIGNATURE="$(xmllint --xpath 'string(//enclosure/@*[local-name()="edSignature"])' "$APPCAST" 2>/dev/null || true)"

# ShipHook publishes the appcast only after the matching signed binary exists.
# A development version bump therefore legitimately precedes the appcast; keep
# validating the published feed's format and signature without blocking it.
[[ -n "$APPCAST_SHORT_VERSION" ]] || fail "appcast short version is missing"
[[ "$APPCAST_BUILD_VERSION" =~ ^[0-9]{10}$ ]] || fail "appcast build '$APPCAST_BUILD_VERSION' is not a valid published build number"

RELEASE_NOTES="$ROOT_DIR/Website/public/release-notes/$MARKETING_VERSION.html"
[[ -f "$RELEASE_NOTES" ]] || fail "release notes missing: $RELEASE_NOTES"
grep -q "Build $CURRENT_PROJECT_VERSION" "$RELEASE_NOTES" || fail "release notes do not mention Build $CURRENT_PROJECT_VERSION"
grep -q "$MARKETING_VERSION.html" "$ROOT_DIR/Website/public/release-notes/index.html" || fail "release notes index does not link $MARKETING_VERSION.html"

if [[ -n "$ENCLOSURE_URL" ]]; then
    if [[ -z "$ENCLOSURE_SIGNATURE" && "${SWIFTMINER_ALLOW_UNSIGNED_APPCAST:-0}" != "1" ]]; then
        fail "appcast enclosure is missing sparkle:edSignature; set SWIFTMINER_ALLOW_UNSIGNED_APPCAST=1 only for draft/local checks"
    fi

    ENCLOSURE_FILE="${SWIFTMINER_ENCLOSURE_FILE:-}"
    if [[ -n "$ENCLOSURE_FILE" ]]; then
        [[ -f "$ENCLOSURE_FILE" ]] || fail "SWIFTMINER_ENCLOSURE_FILE does not exist: $ENCLOSURE_FILE"
        ACTUAL_LENGTH="$(wc -c < "$ENCLOSURE_FILE" | tr -d '[:space:]')"
        APPCAST_LENGTH="$(xmllint --xpath 'string(//enclosure/@length)' "$APPCAST" 2>/dev/null || true)"
        [[ "$ACTUAL_LENGTH" == "$APPCAST_LENGTH" ]] || fail "appcast enclosure length '$APPCAST_LENGTH' does not match file length '$ACTUAL_LENGTH'"
    fi
fi

if [[ "${SWIFTMINER_SKIP_BUILD:-0}" == "1" ]]; then
    echo "Skipping Xcode build checks because SWIFTMINER_SKIP_BUILD=1"
    echo "Release metadata checks passed for SwiftMiner $MARKETING_VERSION ($CURRENT_PROJECT_VERSION)."
    exit 0
fi

xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "generic/platform=macOS" \
    build

INFO_PLIST="$(find "$HOME/Library/Developer/Xcode/DerivedData" -path "*/Build/Products/$CONFIGURATION/SwiftMiner.app/Contents/Info.plist" -print | sort | tail -n 1)"
[[ -n "$INFO_PLIST" ]] || fail "built SwiftMiner Info.plist not found"

BUILT_SHORT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$INFO_PLIST")"
BUILT_BUILD_VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$INFO_PLIST")"
BUILT_FEED_URL="$(/usr/libexec/PlistBuddy -c 'Print SUFeedURL' "$INFO_PLIST")"
BUILT_PUBLIC_KEY="$(/usr/libexec/PlistBuddy -c 'Print SUPublicEDKey' "$INFO_PLIST")"

[[ "$BUILT_SHORT_VERSION" == "$MARKETING_VERSION" ]] || fail "built short version '$BUILT_SHORT_VERSION' does not match '$MARKETING_VERSION'"
[[ "$BUILT_BUILD_VERSION" == "$CURRENT_PROJECT_VERSION" ]] || fail "built build '$BUILT_BUILD_VERSION' does not match '$CURRENT_PROJECT_VERSION'"
[[ -n "$BUILT_FEED_URL" ]] || fail "built SUFeedURL missing"
[[ -n "$BUILT_PUBLIC_KEY" ]] || fail "built SUPublicEDKey missing"
[[ "$BUILT_PUBLIC_KEY" == "$EXPECTED_SPARKLE_PUBLIC_KEY" ]] || fail "built SUPublicEDKey does not match the expected Sparkle EdDSA public key"

echo "Release preflight passed for SwiftMiner $MARKETING_VERSION ($CURRENT_PROJECT_VERSION)."
