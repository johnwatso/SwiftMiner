#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/SwiftMiner.xcodeproj"
SCHEME="${SWIFTMINER_SCHEME:-SwiftMiner}"
CONFIGURATION="${SWIFTMINER_CONFIGURATION:-Release}"
DESTINATION="${SWIFTMINER_DESTINATION:-generic/platform=macOS}"

# Sync to origin/main before building — handles diverged state on persistent runners.
git -C "$ROOT_DIR" fetch --no-tags origin
git -C "$ROOT_DIR" checkout main
git -C "$ROOT_DIR" reset --hard origin/main
git -C "$ROOT_DIR" clean -fdx

# Some CI providers reuse workspaces between runs. If an old SwiftPM-generated
# workspace is still hanging around, remove it so xcodebuild can't auto-pick it.
rm -rf "$ROOT_DIR/.swiftpm"

xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "$DESTINATION" \
  build
