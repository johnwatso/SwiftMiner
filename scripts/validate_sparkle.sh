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
PROJECT_YML="$ROOT_DIR/project.yml"

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

project_yml_value() {
    local key="$1"
    if [[ ! -f "$PROJECT_YML" ]]; then
        return
    fi
    sed -nE "s/^[[:space:]]*$key:[[:space:]]*\"?([^\"]+)\"?[[:space:]]*$/\\1/p" "$PROJECT_YML" | head -n 1
}

resolve_build_setting_reference() {
    local value="$1"
    if [[ "$value" =~ ^\$\(([A-Za-z0-9_]+)\)$ ]]; then
        load_build_settings
        build_setting_value "${BASH_REMATCH[1]}"
    else
        echo "$value"
    fi
}

echo "Validating Sparkle release pipeline..."

if [[ ! -f "$INFO_PLIST" ]]; then
    echo "Error: Info.plist not found at $INFO_PLIST"
    exit 1
fi

FEED_URL=$(plutil -extract SUFeedURL raw "$INFO_PLIST" 2>/dev/null || true)
PUBLIC_KEY=$(plutil -extract SUPublicEDKey raw "$INFO_PLIST" 2>/dev/null || true)

FEED_URL=$(resolve_build_setting_reference "$FEED_URL")
PUBLIC_KEY=$(resolve_build_setting_reference "$PUBLIC_KEY")

if [[ -z "$FEED_URL" || -z "$PUBLIC_KEY" ]]; then
    load_build_settings
fi

if [[ -z "$FEED_URL" ]]; then
    FEED_URL=$(build_setting_value "INFOPLIST_KEY_SUFeedURL")
fi
if [[ -z "$FEED_URL" ]]; then
    FEED_URL=$(build_setting_value "SPARKLE_FEED_URL")
fi
if [[ -z "$FEED_URL" ]]; then
    FEED_URL=$(project_yml_value "SPARKLE_FEED_URL")
fi

if [[ -z "$PUBLIC_KEY" ]]; then
    PUBLIC_KEY=$(build_setting_value "INFOPLIST_KEY_SUPublicEDKey")
fi
if [[ -z "$PUBLIC_KEY" ]]; then
    PUBLIC_KEY=$(build_setting_value "SPARKLE_PUBLIC_ED_KEY")
fi
if [[ -z "$PUBLIC_KEY" ]]; then
    PUBLIC_KEY=$(project_yml_value "SPARKLE_PUBLIC_ED_KEY")
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

if grep -q '<enclosure ' "$APPCAST_STABLE" && ! grep -q "sparkle:edSignature" "$APPCAST_STABLE"; then
    echo "Error: Stable appcast has an enclosure but no sparkle:edSignature."
    exit 1
elif grep -q "sparkle:edSignature" "$APPCAST_STABLE"; then
    echo "Stable appcast includes edSignature"
else
    echo "Stable appcast has no published enclosure yet"
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
    if grep -q '<enclosure ' "$APPCAST_BETA" && ! grep -q "sparkle:edSignature" "$APPCAST_BETA"; then
        echo "Error: Beta appcast has an enclosure but no sparkle:edSignature."
        exit 1
    fi
else
    echo "Beta appcast not found (optional)"
fi

echo "Sparkle validation complete."
