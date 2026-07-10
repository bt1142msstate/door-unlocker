#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCAL_DEVELOPMENT_TEAM_FILE="$ROOT_DIR/ios/DoorUnlockerApp/development-team.local"
PROJECT_PATH="$ROOT_DIR/ios/DoorUnlockerApp/DoorUnlocker.xcodeproj"
SCHEME="DoorUnlocker"
CONFIGURATION="${CONFIGURATION:-Debug}"
BUNDLE_ID="io.github.bt1142msstate.DoorUnlocker"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-/tmp/door-unlocker-ios-device-derived}"
BUILD_DESTINATION="${BUILD_DESTINATION:-generic/platform=iOS}"
CLEAN_DERIVED_DATA="${CLEAN_DERIVED_DATA:-0}"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR

DEVICE_UDID="${DEVICE_UDID:-}"

usage() {
  cat <<USAGE
usage: script/install_ios_app.sh [--device-udid UDID] [--no-launch] [--wireless-only]

Builds Door Unlocker for a connected iPhone, installs it with devicectl, and
launches it. The build uses local /tmp DerivedData so iCloud file-provider
metadata cannot break codesigning.

Environment:
  DEVICE_UDID        Physical iOS device UDID. Auto-detected when omitted.
  DERIVED_DATA_PATH  Defaults to /tmp/door-unlocker-ios-device-derived.
  CONFIGURATION      Defaults to Debug.
  BUILD_DESTINATION Defaults to generic/platform=iOS. Override only for diagnostics.
  CLEAN_DERIVED_DATA Set to 1 to delete DerivedData before building.
  DEVELOPMENT_TEAM   Optional local Apple team id for device signing.

Options:
  --wireless-only    Refuse to install unless CoreDevice reports non-wired transport.
USAGE
}

LAUNCH_APP=1
WIRELESS_ONLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --device-udid)
      shift
      DEVICE_UDID="${1:-}"
      ;;
    --no-launch)
      LAUNCH_APP=0
      ;;
    --wireless-only)
      WIRELESS_ONLY=1
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

status_args=()
if [[ -n "$DEVICE_UDID" ]]; then
  status_args+=("--device-udid" "$DEVICE_UDID")
fi
if [[ "$WIRELESS_ONLY" == "1" ]]; then
  status_args+=("--require-wireless")
fi

if [[ "${#status_args[@]}" -gt 0 ]]; then
  status_json="$("$ROOT_DIR/script/ios_device_status.sh" "${status_args[@]}" --json)"
else
  status_json="$("$ROOT_DIR/script/ios_device_status.sh" --json)"
fi

DEVICE_UDID="$(
  STATUS_JSON="$status_json" /usr/bin/python3 <<'PY'
import json
import os
print(json.loads(os.environ["STATUS_JSON"])["udid"])
PY
)"

if [[ -z "$DEVICE_UDID" ]]; then
  echo "No connected physical iOS device was found." >&2
  echo "Plug in the iPhone or set DEVICE_UDID explicitly." >&2
  exit 1
fi

if [[ "$CLEAN_DERIVED_DATA" == "1" ]]; then
  rm -rf "$DERIVED_DATA_PATH"
fi

echo "Building $SCHEME for $BUILD_DESTINATION..."
build_settings=()
build_setting_count=0
if [[ -z "${DEVELOPMENT_TEAM:-}" && -f "$LOCAL_DEVELOPMENT_TEAM_FILE" ]]; then
  DEVELOPMENT_TEAM="$(tr -d '[:space:]' < "$LOCAL_DEVELOPMENT_TEAM_FILE")"
fi
if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
  build_settings+=("DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM")
  build_setting_count=1
fi

xcodebuild_args=(
  -project "$PROJECT_PATH"
  -scheme "$SCHEME"
  -configuration "$CONFIGURATION"
  -destination "$BUILD_DESTINATION"
  -derivedDataPath "$DERIVED_DATA_PATH"
  -allowProvisioningUpdates
  -allowProvisioningDeviceRegistration
)
if [[ "$build_setting_count" -gt 0 ]]; then
  xcodebuild_args+=("${build_settings[@]}")
fi
xcodebuild_args+=(build)

xcodebuild "${xcodebuild_args[@]}"

APP_PATH="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION-iphoneos/DoorUnlocker.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "Build completed, but app bundle was not found at $APP_PATH." >&2
  exit 1
fi

echo "Installing $APP_PATH..."
xcrun devicectl device install app --device "$DEVICE_UDID" "$APP_PATH"

if [[ "$LAUNCH_APP" == "1" ]]; then
  echo "Launching $BUNDLE_ID..."
  xcrun devicectl device process launch --device "$DEVICE_UDID" --terminate-existing "$BUNDLE_ID"
fi

echo "iPhone app installed."
