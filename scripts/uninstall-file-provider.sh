#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DERIVED_DATA_PATH="${TMPDIR:-/private/tmp}/potassiumProviderFileProviderUninstallDerivedData"
FILE_PROVIDER_BUNDLE_ID="net.weavee.potassiumProvider.FileProvider"
FILE_PROVIDER_APPEX_NAME="potassiumProviderFileProvider.appex"
FILE_PROVIDER_DOCUMENT_GROUP="group.net.weavee.potassiumProvider"
ARCHIVES_DIR="$HOME/Library/Developer/Xcode/Archives"
LSREGISTER_PATH="/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister"
PLISTBUDDY_PATH="/usr/libexec/PlistBuddy"
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

provider_needs_registration_repair() {
  if ! command -v fileproviderctl >/dev/null 2>&1; then
    return 1
  fi

  local provider_dump
  if ! provider_dump="$(fileproviderctl dump "$FILE_PROVIDER_BUNDLE_ID" 2>/dev/null)"; then
    return 1
  fi

  grep -q "document group name: none" <<<"$provider_dump"
}

repair_stale_archived_file_provider_registrations() {
  if ! provider_needs_registration_repair; then
    return 0
  fi

  if [[ ! -d "$ARCHIVES_DIR" || ! -x "$LSREGISTER_PATH" || ! -x "$PLISTBUDDY_PATH" ]]; then
    return 0
  fi

  local repaired=0
  while IFS= read -r -d '' info_plist; do
    local appex_path app_path bundle_id document_group
    appex_path="${info_plist%/Contents/Info.plist}"
    app_path="${appex_path%/Contents/PlugIns/$FILE_PROVIDER_APPEX_NAME}"
    bundle_id="$("$PLISTBUDDY_PATH" -c "Print :CFBundleIdentifier" "$info_plist" 2>/dev/null || true)"
    document_group="$("$PLISTBUDDY_PATH" -c "Print :NSExtension:NSExtensionFileProviderDocumentGroup" "$info_plist" 2>/dev/null || true)"

    if [[ "$bundle_id" == "$FILE_PROVIDER_BUNDLE_ID" && "$document_group" != "$FILE_PROVIDER_DOCUMENT_GROUP" ]]; then
      echo "Unregistering stale archived File Provider app: $app_path"
      "$LSREGISTER_PATH" -u "$app_path" >/dev/null 2>&1 || true
      repaired=1
    fi
  done < <(find "$ARCHIVES_DIR" -path "*/Contents/PlugIns/$FILE_PROVIDER_APPEX_NAME/Contents/Info.plist" -print0 2>/dev/null)

  if [[ "$repaired" -eq 1 ]]; then
    echo "Restarting fileproviderd after stale registration repair..."
    killall fileproviderd >/dev/null 2>&1 || true
    sleep 1
  fi
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

repair_stale_archived_file_provider_registrations

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
