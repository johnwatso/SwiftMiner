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
SKIP_APPCAST_COMMIT=0

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
      SKIP_APPCAST_COMMIT=1
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

DERIVED_DATA_DIR="${SPARKLE_PUBLISHER_DERIVED_DATA_PATH:-$HOME/Library/Developer/Xcode/DerivedData/SwiftMiner-SparklePublisher}"
PROJECT_PATH="$ROOT_DIR/SwiftMiner.xcodeproj"
CONFIGURATION="${SPARKLE_PUBLISHER_CONFIGURATION:-Release}"
PUBLISHER_BINARY="$DERIVED_DATA_DIR/Build/Products/$CONFIGURATION/SparklePublisher"

# ShipHook project inspection can be confused by stale package projects under
# repo-local .build output from earlier script versions.
LEGACY_REPO_DERIVED_DATA_DIR="$ROOT_DIR/.build/xcode"
if [[ -d "$LEGACY_REPO_DERIVED_DATA_DIR" ]]; then
  rm -rf "$LEGACY_REPO_DERIVED_DATA_DIR"
fi

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

env SWIFTMINER_ROOT="$ROOT_DIR" "$PUBLISHER_BINARY" "${PUBLISHER_ARGS[@]}"

publish_appcast_commit_if_possible() {
  if [[ "$SKIP_APPCAST_COMMIT" -eq 1 ]]; then
    echo "Skipping appcast git commit/push by request."
    return 0
  fi

  if ! git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "Skipping appcast git commit/push: working directory is not a git repository."
    return 0
  fi

  local appcast_path="$ROOT_DIR/docs/appcast.xml"
  local release_notes_output=""

  if [[ "$CHANNEL" == "beta" ]]; then
    appcast_path="$ROOT_DIR/docs/beta/appcast.xml"
    if [[ -n "$RELEASE_NOTES_PATH" ]]; then
      release_notes_output="$ROOT_DIR/docs/beta/release-notes/${VERSION}.html"
    fi
  else
    if [[ -n "$RELEASE_NOTES_PATH" ]]; then
      release_notes_output="$ROOT_DIR/docs/release-notes/${VERSION}.html"
    fi
  fi

  local files_to_add=("$appcast_path")
  if [[ -n "$release_notes_output" ]]; then
    files_to_add+=("$release_notes_output")
  fi

  git -C "$ROOT_DIR" add -- "${files_to_add[@]}"

  if git -C "$ROOT_DIR" diff --cached --quiet; then
    echo "No appcast documentation changes to commit."
    return 0
  fi

  local current_branch
  current_branch="$(git -C "$ROOT_DIR" rev-parse --abbrev-ref HEAD)"
  if [[ -z "$current_branch" || "$current_branch" == "HEAD" ]]; then
    echo "Skipping appcast git push: repository is not on a branch."
    return 0
  fi

  local channel_prefix=""
  if [[ "$CHANNEL" == "beta" ]]; then
    channel_prefix="beta "
  fi

  git -C "$ROOT_DIR" commit -m "chore(shiphook): update ${channel_prefix}appcast for SwiftMiner ${VERSION} [shiphook skip]"
  git -C "$ROOT_DIR" push origin "$current_branch"
}

publish_appcast_commit_if_possible
