#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DERIVED_DATA_PATH="${TMPDIR:-/private/tmp}/potassiumProviderFinderStabilityDerivedData"
APP_PATH=""
MODE="preflight"
REQUEST_PERMISSIONS=0
CONFIRMED_LIVE=0
CONFIRMED_RECOVERY=0

usage() {
  cat <<'USAGE'
Usage:
  scripts/run-finder-stability.sh [--app PATH] [--preflight] [--run --yes-live] [--recover-stale-run --yes-recover] [--request-permissions]

Options:
  --app PATH              Use an existing macOS Stability app instead of building.
  --preflight             Verify lab, domain, and consent state without Finder or remote mutation (default).
  --run                   Execute the verified disposable-root scenario sequence.
  --recover-stale-run     Preserve and abandon a local run whose owner process has exited.
  --yes-live              Required with --run; confirms the saved development account and lab may be mutated.
  --yes-recover           Required with --recover-stale-run; confirms local evidence recovery.
  --request-permissions   Ask macOS to present Accessibility/Finder Automation consent prompts.
  --help                  Show this help.

Credentials are accepted only through the app's existing manual-token Keychain flow.
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
    --preflight)
      MODE="preflight"
      shift
      ;;
    --run)
      MODE="run"
      shift
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

if [[ "$MODE" == "run" && "$CONFIRMED_LIVE" -ne 1 ]]; then
  echo "error: --run requires --yes-live" >&2
  exit 2
fi
if [[ "$MODE" == "preflight" && "$CONFIRMED_LIVE" -eq 1 ]]; then
  echo "error: --yes-live is accepted only with --run" >&2
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

if [[ -z "$APP_PATH" ]]; then
  echo "Building the macOS Stability app..."
  env -u INFOMANIAK_TOKEN xcodebuild build \
    -project "$PROJECT_ROOT/potassiumProvider.xcodeproj" \
    -scheme potassiumProvider-Stability \
    -configuration Stability \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED_DATA_PATH"
  APP_PATH="$DERIVED_DATA_PATH/Build/Products/Stability/potassiumProvider.app"
fi

EXECUTABLE_PATH="$APP_PATH/Contents/MacOS/potassiumProvider"
if [[ ! -x "$EXECUTABLE_PATH" ]]; then
  echo "error: Stability app executable not found" >&2
  exit 2
fi

COMMAND_ARGS=(--finder-stability "$MODE")
if [[ "$MODE" == "run" ]]; then
  COMMAND_ARGS+=(--yes-live)
fi
if [[ "$MODE" == "recover" ]]; then
  COMMAND_ARGS+=(--yes-recover)
fi
if [[ "$REQUEST_PERMISSIONS" -eq 1 ]]; then
  COMMAND_ARGS+=(--request-permissions)
fi

set +e
env -u INFOMANIAK_TOKEN "$EXECUTABLE_PATH" "${COMMAND_ARGS[@]}"
STATUS=$?
set -e
if [[ "$STATUS" -eq 3 ]]; then
  echo "Checkpoint reached. Grant the requested macOS consent or complete the reported Finder UI checkpoint, then rerun."
fi
exit "$STATUS"
