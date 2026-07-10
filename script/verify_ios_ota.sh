#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE_ID="io.github.bt1142msstate.DoorUnlocker"
FIRMWARE_UPDATE_ARGUMENT="--debug-install-bundled-firmware"
FIRMWARE_EXPECTED_ARGUMENT="--debug-expected-firmware"
FIRMWARE_VERIFIED_NOTIFICATION_PREFIX="io.github.bt1142msstate.DoorUnlocker.debugFirmwareVerified"
TARGET_FIRMWARE="${TARGET_FIRMWARE:-}"
DEVICE_UDID="${DEVICE_UDID:-}"
PORT_PATH="${PORT_PATH:-}"
POLL_SECONDS="${POLL_SECONDS:-420}"
ALLOW_CURRENT="${ALLOW_CURRENT:-0}"
WIRELESS_ONLY="${WIRELESS_ONLY:-0}"
DFU_PRN="${DFU_PRN:-}"
DFU_OBJECT_PREP_DELAY="${DFU_OBJECT_PREP_DELAY:-}"
DFU_SCAN_TIMEOUT="${DFU_SCAN_TIMEOUT:-}"
DFU_CONNECTION_TIMEOUT="${DFU_CONNECTION_TIMEOUT:-}"
RUN_ID="${RUN_ID:-$(date -u +"%Y%m%dT%H%M%SZ")}"
OTA_TELEMETRY_DIR="${OTA_TELEMETRY_DIR:-$ROOT_DIR/docs/ota-telemetry}"
OTA_REPORT_PATH="${OTA_REPORT_PATH:-$ROOT_DIR/docs/ota-last-run.json}"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR

usage() {
  cat <<USAGE
usage: script/verify_ios_ota.sh [--device-udid UDID] [--target VERSION] [--port PATH] [--allow-current] [--wireless-only]

Installs the iPhone app, launches it with the bundled-firmware OTA debug URL,
and verifies that the target firmware version is reported by the controller.
With --wireless-only, the script refuses to start while the controller USB-C
serial port is visible, launches the iPhone OTA over BLE, and verifies the
result from an iPhone debug notification that is posted only after the app
receives firmware_version:<target> from the controller over BLE.

Environment:
  DEVICE_UDID            Physical iOS device UDID. Auto-detected when omitted.
  TARGET_FIRMWARE        Firmware version to wait for. Defaults to firmware source.
  PORT_PATH              Optional /dev/cu.usbmodem... controller port.
  POLL_SECONDS           Defaults to 420.
  ALLOW_CURRENT          Set to 1 only when checking an already-installed target.
  WIRELESS_ONLY          Set to 1 for --wireless-only behavior.
  DFU_PRN                Optional debug benchmark PRN override, clamped by app.
  DFU_OBJECT_PREP_DELAY  Optional debug benchmark object-prep delay override.
  DFU_SCAN_TIMEOUT       Optional debug benchmark DFU bootloader scan timeout.
  DFU_CONNECTION_TIMEOUT Optional debug benchmark DFU connection timeout.
  RUN_ID                 Optional telemetry run id. Defaults to UTC timestamp.
  OTA_TELEMETRY_DIR      Defaults to docs/ota-telemetry.
  OTA_REPORT_PATH        Defaults to docs/ota-last-run.json.
USAGE
}

notification_suffix() {
  printf '%s' "$1" | LC_ALL=C tr -c '[:alnum:]._-' '_'
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

if [[ "$WIRELESS_ONLY" == "1" ]]; then
  if [[ -n "$("${CLI[@]}" status 2>/dev/null || true)" ]]; then
    echo "Controller USB-C serial is visible. Unplug controller USB-C before running --wireless-only." >&2
    echo "The iPhone can stay connected to the Mac; only the controller must be off USB-C." >&2
    exit 1
  fi
else
  current_status="$("${CLI[@]}" status 2>/dev/null || true)"
  current_firmware="$(printf '%s\n' "$current_status" | sed -n 's/^firmware_version=//p' | head -n 1)"
  if [[ "$current_firmware" == "$TARGET_FIRMWARE" && "$ALLOW_CURRENT" != "1" ]]; then
    echo "Controller is already on $TARGET_FIRMWARE; bump firmware before using this as an OTA proof." >&2
    echo "Use --allow-current only for smoke-checking the script path." >&2
    exit 1
  fi
fi

dist_hash="$(shasum -a 256 "$ROOT_DIR/dist/DoorUnlockerXiao-dfu.zip" | awk '{print $1}')"
bundled_hash="$(shasum -a 256 "$ROOT_DIR/ios/DoorUnlockerApp/DoorUnlocker/Firmware/DoorUnlockerXiao-dfu.zip" | awk '{print $1}')"
package_bytes="$(stat -f %z "$ROOT_DIR/dist/DoorUnlockerXiao-dfu.zip")"
if [[ "$dist_hash" != "$bundled_hash" ]]; then
  echo "Bundled iOS DFU package does not match dist/DoorUnlockerXiao-dfu.zip." >&2
  echo "dist=$dist_hash" >&2
  echo "ios=$bundled_hash" >&2
  exit 1
fi

mkdir -p "$OTA_TELEMETRY_DIR" "$(dirname "$OTA_REPORT_PATH")"
launch_json="$OTA_TELEMETRY_DIR/${RUN_ID}-launch.json"
launch_log="$OTA_TELEMETRY_DIR/${RUN_ID}-launch.log"

write_ota_report() {
  local result="$1"
  local verified_over="$2"
  local duration_seconds="$3"
  local message="$4"
  local ended_at
  ended_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  RESULT="$result" \
  VERIFIED_OVER="$verified_over" \
  DURATION_SECONDS="$duration_seconds" \
  MESSAGE="$message" \
  ENDED_AT="$ended_at" \
  RUN_ID="$RUN_ID" \
  TARGET_FIRMWARE="$TARGET_FIRMWARE" \
  DEVICE_UDID="$DEVICE_UDID" \
  WIRELESS_ONLY="$WIRELESS_ONLY" \
  DIST_HASH="$dist_hash" \
  BUNDLED_HASH="$bundled_hash" \
  PACKAGE_BYTES="$package_bytes" \
  DFU_PRN="$DFU_PRN" \
  DFU_OBJECT_PREP_DELAY="$DFU_OBJECT_PREP_DELAY" \
  DFU_SCAN_TIMEOUT="$DFU_SCAN_TIMEOUT" \
  DFU_CONNECTION_TIMEOUT="$DFU_CONNECTION_TIMEOUT" \
  VERIFIED_NOTIFICATION_NAME="${verified_notification_name:-}" \
  OBSERVER_LOG="${observer_log:-}" \
  OBSERVER_JSON="${observer_json:-}" \
  LAUNCH_LOG="$launch_log" \
  LAUNCH_JSON="$launch_json" \
  OTA_REPORT_PATH="$OTA_REPORT_PATH" \
  /usr/bin/python3 <<'PY'
import json
import os
from pathlib import Path

def optional_path(value):
    return value if value else None

def optional_existing_path(value):
    if not value:
        return None
    return value if Path(value).exists() else None

def optional_int(value):
    if not value:
        return None
    try:
        return int(value)
    except ValueError:
        return None

def optional_float(value):
    if not value:
        return None
    try:
        return float(value)
    except ValueError:
        return None

report = {
    "runId": os.environ["RUN_ID"],
    "result": os.environ["RESULT"],
    "message": os.environ["MESSAGE"],
    "endedAt": os.environ["ENDED_AT"],
    "durationSeconds": int(os.environ["DURATION_SECONDS"]),
    "targetFirmware": os.environ["TARGET_FIRMWARE"],
    "deviceUdid": os.environ["DEVICE_UDID"],
    "wirelessOnly": os.environ["WIRELESS_ONLY"] == "1",
    "verifiedOver": os.environ["VERIFIED_OVER"] or None,
    "package": {
        "bytes": int(os.environ["PACKAGE_BYTES"]),
        "distSha256": os.environ["DIST_HASH"],
        "bundledSha256": os.environ["BUNDLED_HASH"],
    },
    "dfuTuningOverrides": {
        "packetReceiptNotificationParameter": optional_int(os.environ["DFU_PRN"]),
        "dataObjectPreparationDelay": optional_float(os.environ["DFU_OBJECT_PREP_DELAY"]),
        "scanTimeout": optional_float(os.environ["DFU_SCAN_TIMEOUT"]),
        "connectionTimeout": optional_float(os.environ["DFU_CONNECTION_TIMEOUT"]),
    },
    "verification": {
        "darwinNotification": optional_path(os.environ["VERIFIED_NOTIFICATION_NAME"]),
        "observerLog": optional_existing_path(os.environ["OBSERVER_LOG"]),
        "observerJson": optional_existing_path(os.environ["OBSERVER_JSON"]),
        "launchLog": optional_existing_path(os.environ["LAUNCH_LOG"]),
        "launchJson": optional_existing_path(os.environ["LAUNCH_JSON"]),
    },
}

path = Path(os.environ["OTA_REPORT_PATH"])
path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print(f"OTA telemetry report: {path}")
PY
}

"$ROOT_DIR/script/install_ios_app.sh" --device-udid "$DEVICE_UDID" --no-launch

observer_pid=""
observer_log=""
observer_json=""
cleanup_observer() {
  if [[ -n "$observer_pid" ]] && kill -0 "$observer_pid" 2>/dev/null; then
    kill "$observer_pid" 2>/dev/null || true
    wait "$observer_pid" 2>/dev/null || true
  fi
}
trap cleanup_observer EXIT

verified_notification_name=""
if [[ "$WIRELESS_ONLY" == "1" ]]; then
  verified_notification_name="$FIRMWARE_VERIFIED_NOTIFICATION_PREFIX.$(notification_suffix "$TARGET_FIRMWARE")"
  observer_log="$OTA_TELEMETRY_DIR/${RUN_ID}-firmware-observe.log"
  observer_json="$OTA_TELEMETRY_DIR/${RUN_ID}-firmware-observe.json"
  echo "Observing wireless firmware verification notification: $verified_notification_name"
  xcrun devicectl device notification observe \
    --device "$DEVICE_UDID" \
    --name "$verified_notification_name" \
    --session-timeout "$POLL_SECONDS" \
    --timeout "$((POLL_SECONDS + 20))" \
    --json-output "$observer_json" \
    > "$observer_log" 2>&1 &
  observer_pid=$!
  sleep 1
fi

launch_args=(
  "$BUNDLE_ID"
  "$FIRMWARE_UPDATE_ARGUMENT"
  "$FIRMWARE_EXPECTED_ARGUMENT"
  "$TARGET_FIRMWARE"
)

if [[ -n "$DFU_PRN" ]]; then
  launch_args+=("--debug-dfu-prn" "$DFU_PRN")
fi
if [[ -n "$DFU_OBJECT_PREP_DELAY" ]]; then
  launch_args+=("--debug-dfu-object-delay" "$DFU_OBJECT_PREP_DELAY")
fi
if [[ -n "$DFU_SCAN_TIMEOUT" ]]; then
  launch_args+=("--debug-dfu-scan-timeout" "$DFU_SCAN_TIMEOUT")
fi
if [[ -n "$DFU_CONNECTION_TIMEOUT" ]]; then
  launch_args+=("--debug-dfu-connection-timeout" "$DFU_CONNECTION_TIMEOUT")
fi

xcrun devicectl device \
  --json-output "$launch_json" \
  --log-output "$launch_log" \
  process launch \
  --device "$DEVICE_UDID" \
  --terminate-existing \
  "${launch_args[@]}"

start_epoch="$(date +%s)"
if [[ "$WIRELESS_ONLY" == "1" ]]; then
  echo "Wireless-only mode: iPhone OTA is running without controller USB-C."
  echo "Waiting for BLE verification from the iPhone app..."
  deadline=$((start_epoch + POLL_SECONDS))
  while (( "$(date +%s)" <= deadline )); do
    if [[ -n "$observer_log" ]] && grep -Fq "Observed '$verified_notification_name'" "$observer_log"; then
      end_epoch="$(date +%s)"
      duration=$((end_epoch - start_epoch))
      echo "iPhone OTA wirelessly verified in $((end_epoch - start_epoch))s"
      echo "firmware_version=$TARGET_FIRMWARE"
      echo "verified_over=ble"
      write_ota_report "pass" "ble" "$duration" "iPhone OTA verified by post-DFU BLE firmware_version notification."
      exit 0
    fi

    if [[ -n "$observer_pid" ]] && ! kill -0 "$observer_pid" 2>/dev/null; then
      break
    fi

    sleep 1
  done

  echo "Timed out waiting for wireless firmware verification: $verified_notification_name" >&2
  write_ota_report "fail" "" "$(($(date +%s) - start_epoch))" "Timed out waiting for post-DFU BLE firmware_version notification."
  if [[ -n "$observer_log" && -f "$observer_log" ]]; then
    echo "devicectl notification log:" >&2
    sed -n '1,160p' "$observer_log" >&2
  fi
  exit 1
fi

deadline=$((start_epoch + POLL_SECONDS))
echo "Waiting for controller firmware_version=$TARGET_FIRMWARE ..."
while (( "$(date +%s)" <= deadline )); do
  status="$("${CLI[@]}" status 2>/dev/null || true)"
  if printf '%s\n' "$status" | grep -q "firmware_version=$TARGET_FIRMWARE"; then
    end_epoch="$(date +%s)"
    duration=$((end_epoch - start_epoch))
    echo "iPhone OTA verified in $((end_epoch - start_epoch))s"
    printf '%s\n' "$status"
    write_ota_report "pass" "usb-status" "$duration" "iPhone OTA verified by USB-C firmware status poll."
    exit 0
  fi
  sleep 2
done

echo "Timed out waiting for firmware_version=$TARGET_FIRMWARE" >&2
write_ota_report "fail" "" "$(($(date +%s) - start_epoch))" "Timed out waiting for controller firmware_version status."
exit 1
