#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE_ID="io.github.bt1142msstate.DoorUnlocker"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR

DEVICE_UDID="${DEVICE_UDID:-}"
CAPTURE_SECONDS="${CAPTURE_SECONDS:-20}"
INSTALL_APP=0
WIRELESS_ONLY=0
SHOW_ALL=0
EXTRA_ARGS=()

usage() {
  cat <<USAGE
usage: script/monitor_ios_app.sh [--device-udid UDID] [--seconds N] [--install] [--wireless-only] [--all] [-- APP_ARGS...]

Launches the iPhone app through CoreDevice with console capture and saves the
output under docs/ios-telemetry/. This works over USB-C or over Wi-Fi when
CoreDevice reports the iPhone as wireless-ready.

Useful examples:
  script/monitor_ios_app.sh --seconds 12
  script/monitor_ios_app.sh --wireless-only --seconds 20
  script/monitor_ios_app.sh --install --wireless-only --seconds 15

Environment:
  DEVICE_UDID       Optional physical iOS device UDID. Defaults to first iPhone/iPad.
  CAPTURE_SECONDS   Defaults to 20.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device-udid)
      shift
      DEVICE_UDID="${1:-}"
      ;;
    --seconds)
      shift
      CAPTURE_SECONDS="${1:-}"
      ;;
    --install)
      INSTALL_APP=1
      ;;
    --wireless-only)
      WIRELESS_ONLY=1
      ;;
    --all)
      SHOW_ALL=1
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --)
      shift
      EXTRA_ARGS+=("$@")
      break
      ;;
    *)
      EXTRA_ARGS+=("$1")
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
resolved_udid="$(
  STATUS_JSON="$status_json" /usr/bin/python3 <<'PY'
import json
import os
print(json.loads(os.environ["STATUS_JSON"])["udid"])
PY
)"

if [[ "$INSTALL_APP" == "1" ]]; then
  "$ROOT_DIR/script/install_ios_app.sh" --device-udid "$resolved_udid" --no-launch
fi

mkdir -p "$ROOT_DIR/docs/ios-telemetry"
run_id="$(date -u +"%Y%m%dT%H%M%SZ")"
raw_log="$ROOT_DIR/docs/ios-telemetry/${run_id}-iphone-console.log"
summary_log="$ROOT_DIR/docs/ios-telemetry/${run_id}-iphone-summary.log"

echo "Monitoring $BUNDLE_ID on iPhone for ${CAPTURE_SECONDS}s..."
echo "Raw log: $raw_log"

if [[ "${#EXTRA_ARGS[@]}" -gt 0 ]]; then
  extra_args_payload="$(printf '%s\n' "${EXTRA_ARGS[@]}")"
else
  extra_args_payload=""
fi

extra_args_json="$(
  EXTRA_ARGS_PAYLOAD="$extra_args_payload" /usr/bin/python3 <<'PY'
import json
import os
payload = os.environ.get("EXTRA_ARGS_PAYLOAD", "")
args = [] if payload == "" else payload.splitlines()
print(json.dumps(args))
PY
)"

DEVICE_UDID="$resolved_udid" \
BUNDLE_ID="$BUNDLE_ID" \
CAPTURE_SECONDS="$CAPTURE_SECONDS" \
RAW_LOG="$raw_log" \
SUMMARY_LOG="$summary_log" \
SHOW_ALL="$SHOW_ALL" \
EXTRA_ARGS_JSON="$extra_args_json" \
/usr/bin/python3 <<'PY'
import json
import os
import subprocess
import sys

device = os.environ["DEVICE_UDID"]
bundle_id = os.environ["BUNDLE_ID"]
capture_seconds = float(os.environ["CAPTURE_SECONDS"])
raw_log = os.environ["RAW_LOG"]
summary_log = os.environ["SUMMARY_LOG"]
show_all = os.environ["SHOW_ALL"] == "1"
extra_args = json.loads(os.environ["EXTRA_ARGS_JSON"])

cmd = [
    "/usr/bin/xcrun", "devicectl", "device", "process", "launch",
    "--device", device,
    "--terminate-existing",
    "--console",
    bundle_id,
    *extra_args,
]

try:
    completed = subprocess.run(
        cmd,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=capture_seconds,
    )
    output = completed.stdout or ""
except subprocess.TimeoutExpired as exc:
    output = exc.stdout or ""
    if isinstance(output, bytes):
        output = output.decode(errors="replace")

with open(raw_log, "w", encoding="utf-8") as handle:
    handle.write(output)

interesting_tokens = (
    "DUStartup",
    "DUFirmware",
    "FirmwareUpdate",
    "debug_firmware",
    "firmware_",
    "door_command_usable",
    "secure_nonce",
    "peripheral_",
    "state_notify_enabled",
    "control_notify_enabled",
)

if show_all:
    summary = output
else:
    summary_lines = [
        line for line in output.splitlines()
        if any(token in line for token in interesting_tokens)
    ]
    summary = "\n".join(summary_lines)
    if summary:
        summary += "\n"

with open(summary_log, "w", encoding="utf-8") as handle:
    handle.write(summary)

if summary:
    print(summary, end="")
else:
    print("No Door Unlocker diagnostic lines were captured.", file=sys.stderr)
    print("The raw console log was still saved for inspection.", file=sys.stderr)

print(f"Summary log: {summary_log}")
PY

# Leave the app running normally after console capture ends.
xcrun devicectl device process launch \
  --device "$resolved_udid" \
  --terminate-existing \
  "$BUNDLE_ID" >/dev/null
