#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE_ID="io.github.bt1142msstate.DoorUnlocker"
PAYLOAD_URL="doorunlocker://debug-install-bundled-firmware"
TARGET_FIRMWARE="${TARGET_FIRMWARE:-}"
DEVICE_UDID="${DEVICE_UDID:-}"
PORT_PATH="${PORT_PATH:-}"
POLL_SECONDS="${POLL_SECONDS:-420}"
ALLOW_CURRENT="${ALLOW_CURRENT:-0}"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR

usage() {
  cat <<USAGE
usage: script/verify_ios_ota.sh [--device-udid UDID] [--target VERSION] [--port PATH] [--allow-current]

Installs the iPhone app, launches it with the bundled-firmware OTA debug URL,
and polls the XIAO over USB-C until the target firmware version is reported.

Environment:
  DEVICE_UDID      Physical iOS device UDID. Auto-detected when omitted.
  TARGET_FIRMWARE  Firmware version to wait for. Defaults to firmware source.
  PORT_PATH        Optional /dev/cu.usbmodem... controller port.
  POLL_SECONDS     Defaults to 420.
  ALLOW_CURRENT    Set to 1 only when checking an already-installed target.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device-udid)
      shift
      DEVICE_UDID="${1:-}"
      ;;
    --target)
      shift
      TARGET_FIRMWARE="${1:-}"
      ;;
    --port)
      shift
      PORT_PATH="${1:-}"
      ;;
    --allow-current)
      ALLOW_CURRENT=1
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
  { xcrun xctrace list devices 2>/dev/null || true; } |
    sed -n '/^== Devices ==/,/^== Devices Offline ==/p' |
    sed '/^== Devices Offline ==/,$d' |
    grep -E 'iPhone|iPad' |
    grep -v 'Simulator' |
    sed -E 's/.*\(([0-9A-Fa-f-]{20,})\)$/\1/' |
    head -n 1 || true
}

if [[ -z "$DEVICE_UDID" ]]; then
  DEVICE_UDID="$(detect_device_udid)"
fi

if [[ -z "$DEVICE_UDID" ]]; then
  echo "No available physical iOS device was found." >&2
  echo "Unlock the iPhone, keep it near this Mac, and confirm Xcode sees it as available." >&2
  exit 1
fi

if [[ -z "$TARGET_FIRMWARE" ]]; then
  TARGET_FIRMWARE="$(
    sed -n 's/.*CONTROLLER_FIRMWARE_VERSION\[\] = "\([^"]*\)".*/\1/p' \
      "$ROOT_DIR/firmware/DoorUnlockerXiao/DoorUnlockerXiao.ino" |
      head -n 1
  )"
fi

if [[ -z "$TARGET_FIRMWARE" ]]; then
  echo "Could not determine target firmware version." >&2
  exit 1
fi

CLI=("$ROOT_DIR/dist/door-unlocker")
if [[ -n "$PORT_PATH" ]]; then
  CLI+=("--port" "$PORT_PATH")
fi

current_status="$("${CLI[@]}" status 2>/dev/null || true)"
current_firmware="$(printf '%s\n' "$current_status" | sed -n 's/^firmware_version=//p' | head -n 1)"
if [[ "$current_firmware" == "$TARGET_FIRMWARE" && "$ALLOW_CURRENT" != "1" ]]; then
  echo "Controller is already on $TARGET_FIRMWARE; bump firmware before using this as an OTA proof." >&2
  echo "Use --allow-current only for smoke-checking the script path." >&2
  exit 1
fi

dist_hash="$(shasum -a 256 "$ROOT_DIR/dist/DoorUnlockerXiao-dfu.zip" | awk '{print $1}')"
bundled_hash="$(shasum -a 256 "$ROOT_DIR/ios/DoorUnlockerApp/DoorUnlocker/Firmware/DoorUnlockerXiao-dfu.zip" | awk '{print $1}')"
if [[ "$dist_hash" != "$bundled_hash" ]]; then
  echo "Bundled iOS DFU package does not match dist/DoorUnlockerXiao-dfu.zip." >&2
  echo "dist=$dist_hash" >&2
  echo "ios=$bundled_hash" >&2
  exit 1
fi

"$ROOT_DIR/script/install_ios_app.sh" --device-udid "$DEVICE_UDID" --no-launch

xcrun devicectl device process launch \
  --device "$DEVICE_UDID" \
  --terminate-existing \
  --payload-url "$PAYLOAD_URL" \
  "$BUNDLE_ID"

start_epoch="$(date +%s)"
deadline=$((start_epoch + POLL_SECONDS))
echo "Waiting for controller firmware_version=$TARGET_FIRMWARE ..."
while (( "$(date +%s)" <= deadline )); do
  status="$("${CLI[@]}" status 2>/dev/null || true)"
  if printf '%s\n' "$status" | grep -q "firmware_version=$TARGET_FIRMWARE"; then
    end_epoch="$(date +%s)"
    echo "iPhone OTA verified in $((end_epoch - start_epoch))s"
    printf '%s\n' "$status"
    exit 0
  fi
  sleep 2
done

echo "Timed out waiting for firmware_version=$TARGET_FIRMWARE" >&2
exit 1
