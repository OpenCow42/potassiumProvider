#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DERIVED_DATA_PATH="${TMPDIR:-/private/tmp}/potassiumProviderFileProviderUninstallDerivedData"
APP_PATH=""
COMMAND_ARGS=()

usage() {
  cat <<'USAGE'
Usage:
  scripts/uninstall-file-provider.sh [--app /path/to/potassiumProvider.app] [--dry-run] [--yes] [--full-logout] [--hard-purge]

Options:
  --app PATH      Use an existing macOS potassiumProvider.app instead of building.
  --dry-run       Print the uninstall plan without removing domains or local state.
  --yes           Perform the uninstall. Required unless --dry-run is present.
  --full-logout   Also delete the saved OAuth token.
  --hard-purge    Use File Provider remove-all mode, delete ConflictStaging, and delete the OAuth token.
  --help          Show this help.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)
      if [[ $# -lt 2 || -z "$2" ]]; then
        echo "error: --app requires a path" >&2
        exit 2
      fi
      APP_PATH="$2"
      shift 2
      ;;
    --dry-run|--yes|--full-logout|--hard-purge)
      COMMAND_ARGS+=("$1")
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$APP_PATH" ]]; then
  echo "Building macOS potassiumProvider.app..."
  xcodebuild build \
    -project "$PROJECT_ROOT/potassiumProvider.xcodeproj" \
    -scheme potassiumProvider \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED_DATA_PATH"
  APP_PATH="$DERIVED_DATA_PATH/Build/Products/Debug/potassiumProvider.app"
fi

EXECUTABLE_PATH="$APP_PATH/Contents/MacOS/potassiumProvider"
if [[ ! -x "$EXECUTABLE_PATH" ]]; then
  echo "error: app executable not found or not executable: $EXECUTABLE_PATH" >&2
  exit 2
fi

echo "Using app: $APP_PATH"
"$EXECUTABLE_PATH" --file-provider-uninstall "${COMMAND_ARGS[@]}"
