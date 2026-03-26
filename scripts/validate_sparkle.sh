#!/usr/bin/env bash
# validate_sparkle.sh - Validates Sparkle release pipeline integrity.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

INFO_PLIST="$ROOT_DIR/Sources/SwiftMiner/Info.plist"
PROJECT_PATH="$ROOT_DIR/SwiftMiner.xcodeproj"
SCHEME="SwiftMiner"
CONFIGURATION="${SPARKLE_VALIDATION_CONFIGURATION:-Release}"
APPCAST_STABLE="$ROOT_DIR/docs/appcast.xml"
APPCAST_BETA="$ROOT_DIR/docs/beta/appcast.xml"

BUILD_SETTINGS_CACHE=""

load_build_settings() {
    if [[ -n "$BUILD_SETTINGS_CACHE" ]]; then
        return
    fi
    BUILD_SETTINGS_CACHE=$(xcodebuild \
        -project "$PROJECT_PATH" \
        -scheme "$SCHEME" \
        -configuration "$CONFIGURATION" \
        -showBuildSettings 2>/dev/null || true)
}

build_setting_value() {
    local key="$1"
    echo "$BUILD_SETTINGS_CACHE" \
        | sed -nE "s/^[[:space:]]*$key = (.*)$/\\1/p" \
        | head -n 1 \
        | tr -d '"'
}

echo "Validating Sparkle release pipeline..."

if [[ ! -f "$INFO_PLIST" ]]; then
    echo "Error: Info.plist not found at $INFO_PLIST"
    exit 1
fi

FEED_URL=$(plutil -extract SUFeedURL raw "$INFO_PLIST" 2>/dev/null || true)
PUBLIC_KEY=$(plutil -extract SUPublicEDKey raw "$INFO_PLIST" 2>/dev/null || true)

if [[ -z "$FEED_URL" || -z "$PUBLIC_KEY" ]]; then
    load_build_settings
fi

if [[ -z "$FEED_URL" ]]; then
    FEED_URL=$(build_setting_value "INFOPLIST_KEY_SUFeedURL")
fi
if [[ -z "$FEED_URL" ]]; then
    FEED_URL=$(build_setting_value "SPARKLE_FEED_URL")
fi

if [[ -z "$PUBLIC_KEY" ]]; then
    PUBLIC_KEY=$(build_setting_value "INFOPLIST_KEY_SUPublicEDKey")
fi
if [[ -z "$PUBLIC_KEY" ]]; then
    PUBLIC_KEY=$(build_setting_value "SPARKLE_PUBLIC_ED_KEY")
fi

if [[ -z "$FEED_URL" ]]; then
    echo "Error: SUFeedURL is missing. Define INFOPLIST_KEY_SUFeedURL/SPARKLE_FEED_URL in SwiftMiner build settings."
    exit 1
fi
echo "Resolved SUFeedURL: $FEED_URL"

if [[ -z "$PUBLIC_KEY" ]]; then
    echo "Warning: SUPublicEDKey is blank. Set INFOPLIST_KEY_SUPublicEDKey/SPARKLE_PUBLIC_ED_KEY before shipping."
else
    echo "Resolved SUPublicEDKey present"
fi

if [[ ! -f "$APPCAST_STABLE" ]]; then
    echo "Error: Stable appcast missing at $APPCAST_STABLE"
    exit 1
fi

if ! grep -q "sparkle:edSignature" "$APPCAST_STABLE"; then
    echo "Warning: No edSignature found in stable appcast yet."
else
    echo "Stable appcast includes edSignature"
fi

STABLE_URL=$(grep -oE 'url="https://github.com/[^"]+"' "$APPCAST_STABLE" | head -n 1 | cut -d'"' -f2 || true)
if [[ -n "$STABLE_URL" ]]; then
    echo "Checking stable enclosure reachability: $STABLE_URL"
    if curl --output /dev/null --silent --head --fail "$STABLE_URL"; then
        echo "Stable enclosure is reachable"
    else
        echo "Warning: Stable enclosure is not reachable yet"
    fi
else
    echo "Stable appcast has no published enclosure yet"
fi

if [[ -f "$APPCAST_BETA" ]]; then
    echo "Beta appcast found"
    if ! grep -q "sparkle:edSignature" "$APPCAST_BETA"; then
        echo "Warning: No edSignature found in beta appcast yet."
    fi
else
    echo "Beta appcast not found (optional)"
fi

echo "Sparkle validation complete."
