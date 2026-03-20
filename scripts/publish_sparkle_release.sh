#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA_DIR="$ROOT_DIR/.build/xcode"
PROJECT_PATH="$ROOT_DIR/SwiftMiner.xcodeproj"
CONFIGURATION="${SPARKLE_PUBLISHER_CONFIGURATION:-Release}"
PUBLISHER_BINARY="$DERIVED_DATA_DIR/Build/Products/$CONFIGURATION/SparklePublisher"

xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme SparklePublisher \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA_DIR" \
  build

exec env SWIFTMINER_ROOT="$ROOT_DIR" "$PUBLISHER_BINARY" "$@"
