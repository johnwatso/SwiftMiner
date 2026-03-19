#!/usr/bin/env bash
# validate_sparkle.sh - Validates Sparkle release pipeline integrity.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

INFO_PLIST="$ROOT_DIR/Sources/SwiftTwitchMinerApp/Info.plist"
APPCAST_STABLE="$ROOT_DIR/docs/appcast.xml"
APPCAST_BETA="$ROOT_DIR/docs/beta/appcast.xml"

echo "Validating Sparkle release pipeline..."

if [[ ! -f "$INFO_PLIST" ]]; then
    echo "Error: Info.plist not found at $INFO_PLIST"
    exit 1
fi

FEED_URL=$(plutil -extract SUFeedURL raw "$INFO_PLIST" || echo "")
PUBLIC_KEY=$(plutil -extract SUPublicEDKey raw "$INFO_PLIST" || echo "")

if [[ -z "$FEED_URL" ]]; then
    echo "Error: SUFeedURL missing in Info.plist"
    exit 1
fi
echo "SUFeedURL template: $FEED_URL"

if [[ -z "$PUBLIC_KEY" ]]; then
    echo "Warning: SUPublicEDKey is blank in Info.plist template. Set SPARKLE_PUBLIC_ED_KEY in build settings before shipping."
else
    echo "SUPublicEDKey template present"
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

STABLE_URL=$(grep -oE 'url="https://github.com/[^"]+"' "$APPCAST_STABLE" | head -n 1 | cut -d'"' -f2)
if [[ -n "$STABLE_URL" ]]; then
    echo "Checking stable enclosure reachability: $STABLE_URL"
    if curl --output /dev/null --silent --head --fail "$STABLE_URL"; then
        echo "Stable enclosure is reachable"
    else
        echo "Warning: Stable enclosure is not reachable yet"
    fi
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
