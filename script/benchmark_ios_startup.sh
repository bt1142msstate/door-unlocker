#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE_ID="io.github.bt1142msstate.DoorUnlocker"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR

DEVICE_UDID="${DEVICE_UDID:-}"
INSTALL_APP=0
CAPTURE_SECONDS="${CAPTURE_SECONDS:-10}"

usage() {
  cat <<USAGE
usage: script/benchmark_ios_startup.sh [--device-udid UDID] [--install]

Launches Door Unlocker on a connected iPhone with console capture and prints
DEBUG-only DUStartup timing lines. Use --install to build/install first.

Environment:
  DEVICE_UDID       Physical iOS device UDID. Auto-detected when omitted.
  CAPTURE_SECONDS   Console capture timeout. Defaults to 10.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device-udid)
      shift
      DEVICE_UDID="${1:-}"
      ;;
    --install)
      INSTALL_APP=1
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
  exit 1
fi

if [[ "$INSTALL_APP" == "1" ]]; then
  "$ROOT_DIR/script/install_ios_app.sh" --device-udid "$DEVICE_UDID" --no-launch
fi

DEVICE_UDID="$DEVICE_UDID" BUNDLE_ID="$BUNDLE_ID" CAPTURE_SECONDS="$CAPTURE_SECONDS" /usr/bin/python3 <<'PY'
import os
import subprocess
import sys

device = os.environ["DEVICE_UDID"]
bundle_id = os.environ["BUNDLE_ID"]
capture_seconds = float(os.environ["CAPTURE_SECONDS"])
env = os.environ.copy()

cmd = [
    "/usr/bin/xcrun", "devicectl", "device", "process", "launch",
    "--timeout", str(int(capture_seconds)),
    "--device", device,
    "--terminate-existing",
    "--console",
    bundle_id,
]

try:
    completed = subprocess.run(
        cmd,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=capture_seconds + 3,
    )
    output = completed.stdout
except subprocess.TimeoutExpired as exc:
    output = exc.stdout or ""
    if isinstance(output, bytes):
        output = output.decode(errors="replace")

lines = [line for line in output.splitlines() if "DUStartup" in line]
if lines:
    print("\n".join(lines))
else:
    print("No DUStartup lines captured.", file=sys.stderr)
    sys.exit(1)
PY

xcrun devicectl device process launch \
  --device "$DEVICE_UDID" \
  --terminate-existing \
  "$BUNDLE_ID" >/dev/null
