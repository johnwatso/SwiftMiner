#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_YML="$ROOT_DIR/project.yml"
PBXPROJ="$ROOT_DIR/SwiftMiner.xcodeproj/project.pbxproj"
APPCAST="$ROOT_DIR/docs/appcast.xml"

BUILD_NUMBER="${1:-$(date +%Y%m%d%H)}"

if [[ ! "$BUILD_NUMBER" =~ ^[0-9]{10}$ ]]; then
    echo "error: build number must use yyyyMMddHH, got '$BUILD_NUMBER'" >&2
    exit 1
fi

MARKETING_VERSION="$(sed -nE 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"?([^"]+)"?[[:space:]]*$/\1/p' "$PROJECT_YML" | head -n 1)"
[[ -n "$MARKETING_VERSION" ]] || {
    echo "error: MARKETING_VERSION missing from project.yml" >&2
    exit 1
}

perl -0pi -e 's/CURRENT_PROJECT_VERSION: "\d{10}"/CURRENT_PROJECT_VERSION: "'$BUILD_NUMBER'"/g' "$PROJECT_YML"
perl -0pi -e 's/CURRENT_PROJECT_VERSION = \d{10};/CURRENT_PROJECT_VERSION = '$BUILD_NUMBER';/g' "$PBXPROJ"

if [[ -f "$APPCAST" ]]; then
    perl -0pi -e 's#<sparkle:version>\d{10}</sparkle:version>#<sparkle:version>'$BUILD_NUMBER'</sparkle:version>#g' "$APPCAST"
    perl -0pi -e 's#<sparkle:shortVersionString>[^<]+</sparkle:shortVersionString>#<sparkle:shortVersionString>'$MARKETING_VERSION'</sparkle:shortVersionString>#g' "$APPCAST"
fi

RELEASE_NOTES="$ROOT_DIR/docs/release-notes/$MARKETING_VERSION.html"
if [[ -f "$RELEASE_NOTES" ]]; then
    perl -0pi -e 's/Build \d{10}/Build '$BUILD_NUMBER'/g' "$RELEASE_NOTES"
fi

INDEX="$ROOT_DIR/docs/release-notes/index.html"
if [[ -f "$INDEX" ]]; then
    perl -0pi -e 's/Build \d{10}/Build '$BUILD_NUMBER'/g' "$INDEX"
fi

echo "Updated SwiftMiner $MARKETING_VERSION build number to $BUILD_NUMBER."
