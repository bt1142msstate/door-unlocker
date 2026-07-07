#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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
usage: script/install_ios_app.sh [--device-udid UDID] [--no-launch]

Builds Door Unlocker for a connected iPhone, installs it with devicectl, and
launches it. The build uses local /tmp DerivedData so iCloud file-provider
metadata cannot break codesigning.

Environment:
  DEVICE_UDID        Physical iOS device UDID. Auto-detected when omitted.
  DERIVED_DATA_PATH  Defaults to /tmp/door-unlocker-ios-device-derived.
  CONFIGURATION      Defaults to Debug.
  BUILD_DESTINATION Defaults to generic/platform=iOS. Override only for diagnostics.
  CLEAN_DERIVED_DATA Set to 1 to delete DerivedData before building.
USAGE
}

LAUNCH_APP=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --device-udid)
      shift
      DEVICE_UDID="${1:-}"
      ;;
    --no-launch)
      LAUNCH_APP=0
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

detect_device_udid() {
  xcrun xctrace list devices 2>/dev/null |
    sed '/^== Simulators ==/,$d' |
    grep -E 'iPhone|iPad' |
    grep -v 'Simulator' |
    sed -E 's/.*\(([0-9A-Fa-f-]{20,})\)$/\1/' |
    head -n 1
}

if [[ -z "$DEVICE_UDID" ]]; then
  DEVICE_UDID="$(detect_device_udid)"
fi

if [[ -z "$DEVICE_UDID" ]]; then
  echo "No connected physical iOS device was found." >&2
  echo "Plug in the iPhone or set DEVICE_UDID explicitly." >&2
  exit 1
fi

if [[ "$CLEAN_DERIVED_DATA" == "1" ]]; then
  rm -rf "$DERIVED_DATA_PATH"
fi

echo "Building $SCHEME for $BUILD_DESTINATION..."
xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "$BUILD_DESTINATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration \
  build

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
