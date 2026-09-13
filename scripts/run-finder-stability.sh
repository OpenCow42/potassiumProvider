#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DERIVED_DATA_PATH="${POTASSIUM_STABILITY_DERIVED_DATA:-${TMPDIR:-/private/tmp}/potassiumProviderFinderStabilityDerivedData}"
APP_PATH=""
BUILD_APP=0
INSTALLED_APP_PATH="$HOME/Applications/Potassium Stability.app"
MODE="preflight"
REQUEST_PERMISSIONS=0
CONFIRMED_LIVE=0
CONFIRMED_RECOVERY=0
CONFLICT_CASE=""
EXTENSION_STATE=""
INCLUDE_PERMANENT_DELETION=0

usage() {
  cat <<'USAGE'
Usage:
  scripts/run-finder-stability.sh [--app PATH | --build] [--preflight] [--provision --yes-live] [--run --yes-live] [--conflicts [--case CASE] --yes-live] [--watch] [--recover-stale-run --yes-recover] [--request-permissions]

Options:
  --app PATH              Use a specific existing macOS Stability app.
  --build                 Build and install at ~/Applications/Potassium Stability.app.
  --preflight             Verify lab, domain, and consent state without Finder or remote mutation (default).
  --provision             Create or resume the isolated lab inside Private using the saved Keychain account.
  --watch                 Show sanitized active-run diagnostics without mutation.
  --run                   Execute the verified disposable-root scenario sequence.
  --include-permanent-deletion  Include scenario 12 and its exact-item confirmation; requires --run. Default: defer deletion and continue 13–16.
  --conflicts             Run independent conflict cases, each with fresh fixtures and evidence.
  --case CASE             Select one conflict case; requires --conflicts.
  --extension-state MODE  Require fresh or running extension evidence for --run or --conflicts.
  --recover-stale-run     Preserve and abandon a local run whose owner process has exited.
  --yes-live              Required with --run, --provision, or --conflicts; confirms the saved development account and lab may be mutated.
  --yes-recover           Required with --recover-stale-run; confirms local evidence recovery.
  --request-permissions   Ask macOS to present Accessibility/Finder Automation consent prompts.
  --help                  Show this help.

Credentials stay in the app's existing OAuth or manual-token Keychain flow.
The installed Stability app is reused unless --build is supplied or it is absent.
Exit 4 means all 15 selected scenarios passed with deletion deferred, not full acceptance.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build)
      BUILD_APP=1
      shift
      ;;
    --app)
      if [[ $# -lt 2 || -z "$2" ]]; then
        echo "error: --app requires a path" >&2
        exit 2
      fi
      APP_PATH="$2"
      shift 2
      ;;
    --preflight)
      MODE="preflight"
      shift
      ;;
    --provision)
      MODE="provision"
      shift
      ;;
    --watch)
      MODE="watch"
      shift
      ;;
    --run)
      MODE="run"
      shift
      ;;
    --conflicts)
      MODE="conflicts"
      shift
      ;;
    --include-permanent-deletion)
      if [[ "$INCLUDE_PERMANENT_DELETION" -eq 1 ]]; then exit 2; fi
      INCLUDE_PERMANENT_DELETION=1
      shift
      ;;
    --extension-state)
      if [[ $# -lt 2 || -z "$2" || -n "$EXTENSION_STATE" ]]; then exit 2; fi
      EXTENSION_STATE="$2"
      shift 2
      ;;
    --case)
      if [[ $# -lt 2 || -z "$2" ]]; then exit 2; fi
      CONFLICT_CASE="$2"
      shift 2
      ;;
    --recover-stale-run)
      MODE="recover"
      shift
      ;;
    --yes-live)
      CONFIRMED_LIVE=1
      shift
      ;;
    --yes-recover)
      CONFIRMED_RECOVERY=1
      shift
      ;;
    --request-permissions)
      REQUEST_PERMISSIONS=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown option" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "$INCLUDE_PERMANENT_DELETION" -eq 1 && "$MODE" != "run" ]]; then
  echo "error: --include-permanent-deletion requires --run" >&2
  exit 2
fi
if [[ -n "$EXTENSION_STATE" && ( ( "$MODE" != "conflicts" && "$MODE" != "run" ) || ( "$EXTENSION_STATE" != "fresh" && "$EXTENSION_STATE" != "running" ) ) ]]; then
  echo "error: --extension-state requires --run or --conflicts and fresh or running" >&2
  exit 2
fi
if [[ ( "$MODE" == "run" || "$MODE" == "provision" || "$MODE" == "conflicts" ) && "$CONFIRMED_LIVE" -ne 1 ]]; then
  echo "error: --run, --provision, and --conflicts require --yes-live" >&2
  exit 2
fi
if [[ "$MODE" != "run" && "$MODE" != "provision" && "$MODE" != "conflicts" && "$CONFIRMED_LIVE" -eq 1 ]]; then
  echo "error: --yes-live is accepted only with --run, --provision, or --conflicts" >&2
  exit 2
fi
if [[ "$MODE" == "recover" && "$CONFIRMED_RECOVERY" -ne 1 ]]; then
  echo "error: --recover-stale-run requires --yes-recover" >&2
  exit 2
fi
if [[ "$MODE" != "recover" && "$CONFIRMED_RECOVERY" -eq 1 ]]; then
  echo "error: --yes-recover is accepted only with --recover-stale-run" >&2
  exit 2
fi
if [[ "$MODE" == "recover" && "$CONFIRMED_LIVE" -eq 1 ]]; then
  echo "error: --yes-live is not accepted with --recover-stale-run" >&2
  exit 2
fi
if [[ "$MODE" == "recover" && "$REQUEST_PERMISSIONS" -eq 1 ]]; then
  echo "error: --request-permissions is not accepted with --recover-stale-run" >&2
  exit 2
fi

if [[ -n "$CONFLICT_CASE" && "$MODE" != "conflicts" ]]; then
  echo "error: --case requires --conflicts" >&2
  exit 2
fi
if [[ -n "$CONFLICT_CASE" ]]; then
  case "$CONFLICT_CASE" in
    content-before-preflight|content-after-preflight|rename-rename|move-move|edit-rename|edit-move) ;;
    *) echo "error: unknown conflict case" >&2; exit 2 ;;
  esac
fi

if [[ -n "$APP_PATH" && "$BUILD_APP" -eq 1 ]]; then
  echo "error: --app and --build are mutually exclusive" >&2
  exit 2
fi
if [[ -z "$APP_PATH" ]]; then
  APP_PATH="$INSTALLED_APP_PATH"
  if [[ ! -d "$APP_PATH" ]]; then BUILD_APP=1; fi
fi
if [[ "$BUILD_APP" -eq 1 ]]; then
  # Replacing a running bundle can mix code versions and invalidate evidence.
  if ps -axo comm= | /usr/bin/grep -Fq "$APP_PATH/Contents/MacOS/potassiumProvider"; then
    echo "error: stop the installed Stability app before rebuilding" >&2
    exit 2
  fi
  if [[ -e "$HOME/Library/Group Containers/group.net.weavee.potassiumProvider/StabilityRuns/current-run.json" ]]; then
    echo "error: finish or explicitly recover the active Stability run before rebuilding" >&2
    exit 2
  fi
  echo "Building the macOS Stability app..."
  env -u INFOMANIAK_TOKEN xcodebuild build \
    -project "$PROJECT_ROOT/potassiumProvider.xcodeproj" \
    -scheme potassiumProvider-Stability \
    -configuration Stability \
    -destination 'platform=macOS' \
    -allowProvisioningUpdates \
    -derivedDataPath "$DERIVED_DATA_PATH"
  BUILT_APP_PATH="$DERIVED_DATA_PATH/Build/Products/Stability/potassiumProvider.app"
  /usr/bin/codesign --verify --deep --strict "$BUILT_APP_PATH"
  mkdir -p "$(dirname "$APP_PATH")"
  INSTALL_STAGING="$(mktemp -d "$(dirname "$APP_PATH")/.potassium-stability-install.XXXXXX")"
  /usr/bin/ditto "$BUILT_APP_PATH" "$INSTALL_STAGING/candidate.bundle"
  /usr/bin/codesign --verify --deep --strict "$INSTALL_STAGING/candidate.bundle"
  trap 'if [[ ! -d "$APP_PATH" && -n "${BACKUP_PATH:-}" && -d "$BACKUP_PATH" ]]; then mv "$BACKUP_PATH" "$APP_PATH"; fi' EXIT
  # Only the selected app's embedded processes are restarted, and only after
  # excluding an active run. Never terminate fileproviderd or other providers.
  while read -r PROVIDER_PID PROVIDER_COMMAND; do
    case "$PROVIDER_COMMAND" in
      "$APP_PATH/Contents/PlugIns/potassiumProviderFileProvider.appex/Contents/MacOS/potassiumProviderFileProvider"|"$APP_PATH/Contents/PlugIns/potassiumProviderActions.appex/Contents/MacOS/potassiumProviderActions")
        kill -TERM "$PROVIDER_PID" 2>/dev/null || true
        ;;
    esac
  done < <(ps -axo pid=,comm=)
  if [[ -d "$APP_PATH" ]]; then
    # Keep one recoverable backup outside LaunchServices' app directories.
    BACKUP_ROOT="$HOME/Library/Application Support/potassiumProvider/StabilityBuildBackup"
    mkdir -p "$BACKUP_ROOT"
    BACKUP_PATH="$(mktemp -d "$BACKUP_ROOT/build.XXXXXX")/previous.bundle"
    mv "$APP_PATH" "$BACKUP_PATH"
  fi
  mv "$INSTALL_STAGING/candidate.bundle" "$APP_PATH"
  rmdir "$INSTALL_STAGING"
  /usr/bin/codesign --verify --deep --strict "$APP_PATH"
  for EXTENSION in potassiumProviderFileProvider potassiumProviderActions; do
    if [[ -n "${BACKUP_PATH:-}" ]]; then
      /usr/bin/pluginkit -r "$BACKUP_PATH/Contents/PlugIns/$EXTENSION.appex" 2>/dev/null || true
    fi
    /usr/bin/pluginkit -r "$BUILT_APP_PATH/Contents/PlugIns/$EXTENSION.appex" 2>/dev/null || true
    /usr/bin/pluginkit -a "$APP_PATH/Contents/PlugIns/$EXTENSION.appex"
  done
  trap - EXIT
fi

EXECUTABLE_PATH="$APP_PATH/Contents/MacOS/potassiumProvider"
if [[ ! -x "$EXECUTABLE_PATH" ]]; then
  echo "error: Stability app executable not found" >&2
  exit 2
fi

COMMAND_ARGS=(--finder-stability "$MODE")
if [[ "$INCLUDE_PERMANENT_DELETION" -eq 1 ]]; then COMMAND_ARGS+=(--include-permanent-deletion); fi
if [[ -n "$EXTENSION_STATE" ]]; then COMMAND_ARGS+=(--extension-state "$EXTENSION_STATE"); fi
if [[ -n "$CONFLICT_CASE" ]]; then COMMAND_ARGS+=(--case "$CONFLICT_CASE"); fi
if [[ "$MODE" == "run" || "$MODE" == "provision" || "$MODE" == "conflicts" ]]; then
  COMMAND_ARGS+=(--yes-live)
fi
if [[ "$MODE" == "recover" ]]; then
  COMMAND_ARGS+=(--yes-recover)
fi
if [[ "$REQUEST_PERMISSIONS" -eq 1 ]]; then
  COMMAND_ARGS+=(--request-permissions)
fi

# LaunchServices gives the signed app its own macOS privacy identity. Keeping
# stdout in a local file also lets the app survive the invoking terminal closing.
if [[ "$MODE" == "watch" || "$MODE" == "recover" ]]; then
  exec env -u INFOMANIAK_TOKEN "$EXECUTABLE_PATH" "${COMMAND_ARGS[@]}"
fi
RUN_LOG="$(mktemp -t potassium-finder-stability)"
RUN_ERROR_LOG="${RUN_LOG}.stderr"
: > "$RUN_ERROR_LOG"
chmod 600 "$RUN_LOG" "$RUN_ERROR_LOG"
echo "Local runner log: $RUN_LOG"
TAIL_PID=""
trap 'if [[ -n "$TAIL_PID" ]]; then kill "$TAIL_PID" 2>/dev/null || true; fi' EXIT
/usr/bin/tail -n +1 -f "$RUN_LOG" &
TAIL_PID=$!
set +e
env -u INFOMANIAK_TOKEN /usr/bin/open -n -W --stdout "$RUN_LOG" --stderr "$RUN_ERROR_LOG" \
  -a "$APP_PATH" --args "${COMMAND_ARGS[@]}"
LAUNCH_STATUS=$?
set -e
if [[ "$LAUNCH_STATUS" -ne 0 ]]; then exit "$LAUNCH_STATUS"; fi
# open returns launch status, not the app's exit code. Interpret only the exact
# closed terminal messages emitted by FinderStabilityCommandResult.
if /usr/bin/grep -q '^finder stability run: evidence bundle sealed$' "$RUN_LOG"; then exit 0; fi
if /usr/bin/grep -q '^finder stability run: 15 scenarios passed; permanent deletion deferred; evidence bundle sealed; full acceptance incomplete$' "$RUN_LOG"; then exit 4; fi
if /usr/bin/grep -q '^finder stability preflight: ready$' "$RUN_LOG"; then exit 0; fi
if /usr/bin/grep -q '^finder stability checkpoint:' "$RUN_LOG"; then exit 3; fi
if /usr/bin/grep -q '^finder stability rejected:' "$RUN_LOG"; then exit 2; fi
exit 1
