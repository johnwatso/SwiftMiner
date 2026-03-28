#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  scripts/publish_sparkle_release.sh <version> <exported-app-or-zip> [release-notes-html] [--channel stable|beta]
  scripts/publish_sparkle_release.sh --version <version> --artifact <path> [--release-notes <path>] [--channel stable|beta]

ShipHook-compatible options accepted:
  --app-name <value>             Accepted for compatibility (handled by publisher defaults)
  --repo-owner <value>           Accepted for compatibility (publisher derives from git remote)
  --repo-name <value>            Accepted for compatibility (publisher derives from git remote)
  --docs-dir <path>              Accepted for compatibility
  --releases-dir <path>          Accepted for compatibility
  --tag-prefix <value>           Accepted for compatibility
  --release-title <value>        Accepted for compatibility
  --download-url-base <url>      Accepted for compatibility
  --pages-base-url <url>         Accepted for compatibility
  --working-dir <path>           Overrides repository root used by SparklePublisher
  --skip-appcast-commit          Accepted for compatibility
USAGE
}

VERSION=""
ARTIFACT_PATH=""
RELEASE_NOTES_PATH=""
CHANNEL="${SHIPHOOK_RELEASE_CHANNEL:-stable}"
WORKING_DIR=""

if [[ $# -ge 2 && "$1" != --* ]]; then
  VERSION="$1"
  ARTIFACT_PATH="$2"
  shift 2
  if [[ $# -gt 0 && "$1" != --* ]]; then
    RELEASE_NOTES_PATH="$1"
    shift
  fi
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      VERSION="${2:-}"
      shift 2
      ;;
    --artifact)
      ARTIFACT_PATH="${2:-}"
      shift 2
      ;;
    --release-notes)
      RELEASE_NOTES_PATH="${2:-}"
      shift 2
      ;;
    --channel)
      CHANNEL="${2:-}"
      shift 2
      ;;
    --working-dir)
      WORKING_DIR="${2:-}"
      shift 2
      ;;
    --app-name|--repo-owner|--repo-name|--docs-dir|--releases-dir|--tag-prefix|--release-title|--download-url-base|--pages-base-url)
      # Accepted for ShipHook compatibility; SparklePublisher derives these internally.
      shift 2
      ;;
    --skip-appcast-commit)
      # SparklePublisher does not auto-commit appcast changes.
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$VERSION" || -z "$ARTIFACT_PATH" ]]; then
  usage
  exit 1
fi

if [[ "$CHANNEL" != "stable" && "$CHANNEL" != "beta" ]]; then
  echo "Unsupported channel: $CHANNEL" >&2
  exit 1
fi

if [[ -n "$WORKING_DIR" ]]; then
  ROOT_DIR="$(cd "$WORKING_DIR" && pwd)"
else
  ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

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

PUBLISHER_ARGS=(--version "$VERSION" --artifact "$ARTIFACT_PATH" --channel "$CHANNEL")
if [[ -n "$RELEASE_NOTES_PATH" ]]; then
  PUBLISHER_ARGS+=(--release-notes "$RELEASE_NOTES_PATH")
fi

exec env SWIFTMINER_ROOT="$ROOT_DIR" "$PUBLISHER_BINARY" "${PUBLISHER_ARGS[@]}"
