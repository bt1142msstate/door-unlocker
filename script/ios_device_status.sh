#!/usr/bin/env bash
set -euo pipefail

DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR

DEVICE_UDID="${DEVICE_UDID:-}"
REQUIRE_WIRELESS=0
JSON_ONLY=0

usage() {
  cat <<USAGE
usage: script/ios_device_status.sh [--device-udid UDID] [--require-wireless] [--json]

Reports whether Xcode/CoreDevice can currently use a physical iPhone.
Use --require-wireless before wireless app install, launch, or monitoring.

Environment:
  DEVICE_UDID  Optional physical iOS device UDID. Defaults to first iPhone/iPad.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device-udid)
      shift
      DEVICE_UDID="${1:-}"
      ;;
    --require-wireless)
      REQUIRE_WIRELESS=1
      ;;
    --json)
      JSON_ONLY=1
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

tmp_json="$(mktemp)"
trap 'rm -f "$tmp_json"' EXIT

list_devices() {
  local attempt
  for attempt in 1 2 3 4 5; do
    if xcrun devicectl list devices --json-output "$tmp_json" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.4
  done
  return 1
}

# Asking CoreDevice for details actively establishes the local-network tunnel.
# A passive device list can otherwise report a paired wireless phone as stale.
list_devices

if [[ -z "$DEVICE_UDID" ]]; then
  DEVICE_UDID="$(/usr/bin/python3 - "$tmp_json" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    devices = json.load(handle).get("result", {}).get("devices", [])
for device in devices:
    hardware = device.get("hardwareProperties", {})
    if hardware.get("reality") == "physical" and hardware.get("platform") in ("iOS", "iPadOS"):
        print(hardware.get("udid") or device.get("identifier") or "")
        break
PY
)"
fi

# The initial list discovers the default phone. Requesting details then actively
# establishes its local-network tunnel; refresh the list so callers see that state.
if [[ -n "$DEVICE_UDID" ]]; then
  for attempt in 1 2 3; do
    if xcrun devicectl device info details --device "$DEVICE_UDID" >/dev/null 2>&1; then
      break
    fi
    sleep 0.4
  done
  list_devices
fi

DEVICE_UDID="$DEVICE_UDID" REQUIRE_WIRELESS="$REQUIRE_WIRELESS" JSON_ONLY="$JSON_ONLY" /usr/bin/python3 - "$tmp_json" <<'PY'
import json
import os
import sys

path = sys.argv[1]
requested_udid = os.environ["DEVICE_UDID"].strip()
require_wireless = os.environ["REQUIRE_WIRELESS"] == "1"
json_only = os.environ["JSON_ONLY"] == "1"

with open(path, "r", encoding="utf-8") as handle:
    payload = json.load(handle)

devices = payload.get("result", {}).get("devices", [])
physical_ios = []
for device in devices:
    hardware = device.get("hardwareProperties", {})
    if hardware.get("reality") != "physical":
        continue
    if hardware.get("platform") not in ("iOS", "iPadOS"):
        continue
    physical_ios.append(device)

selected = None
for device in physical_ios:
    hardware = device.get("hardwareProperties", {})
    identifiers = {
        str(device.get("identifier", "")),
        str(hardware.get("udid", "")),
        str(hardware.get("serialNumber", "")),
        str(device.get("deviceProperties", {}).get("name", "")),
    }
    if requested_udid and requested_udid in identifiers:
        selected = device
        break

if selected is None and not requested_udid and physical_ios:
    selected = physical_ios[0]

if selected is None:
    print("No available physical iOS device was found.", file=sys.stderr)
    print("Unlock the iPhone and connect it by USB-C once, or keep it paired on the same Wi-Fi.", file=sys.stderr)
    sys.exit(1)

hardware = selected.get("hardwareProperties", {})
properties = selected.get("deviceProperties", {})
connection = selected.get("connectionProperties", {})
capabilities = {
    capability.get("featureIdentifier", "")
    for capability in selected.get("capabilities", [])
}
transport = connection.get("transportType") or "unavailable"
tunnel = connection.get("tunnelState") or "unavailable"
pairing = connection.get("pairingState") or "unknown"
ddi = bool(properties.get("ddiServicesAvailable"))
wireless_ready = transport not in ("wired", "unavailable", "") and tunnel == "connected" and ddi
can_acquire_tunnel = "com.apple.coredevice.feature.connectdevice" in capabilities
usable = (
    pairing == "paired"
    and properties.get("developerModeStatus") == "enabled"
    and properties.get("bootState") == "booted"
    and (tunnel == "connected" or can_acquire_tunnel)
)

summary = {
    "name": properties.get("name") or hardware.get("marketingName") or "iPhone",
    "udid": hardware.get("udid"),
    "identifier": selected.get("identifier"),
    "transportType": transport,
    "tunnelState": tunnel,
    "pairingState": pairing,
    "developerModeStatus": properties.get("developerModeStatus"),
    "ddiServicesAvailable": ddi,
    "usable": usable,
    "canAcquireTunnel": can_acquire_tunnel,
    "wirelessReady": wireless_ready,
    "localHostnames": connection.get("localHostnames") or [],
    "potentialHostnames": connection.get("potentialHostnames") or [],
}

if json_only:
    print(json.dumps(summary, indent=2, sort_keys=True))
else:
    print(f"name={summary['name']}")
    print(f"udid={summary['udid']}")
    print(f"identifier={summary['identifier']}")
    print(f"transport={summary['transportType']}")
    print(f"tunnel={summary['tunnelState']}")
    print(f"pairing={summary['pairingState']}")
    print(f"developer_mode={summary['developerModeStatus']}")
    print(f"ddi_services={str(summary['ddiServicesAvailable']).lower()}")
    print(f"usable={str(summary['usable']).lower()}")
    print(f"can_acquire_tunnel={str(summary['canAcquireTunnel']).lower()}")
    print(f"wireless_ready={str(summary['wirelessReady']).lower()}")
    if summary["localHostnames"]:
        print("local_hostnames=" + ",".join(summary["localHostnames"]))

if not usable:
    print("Device is known to CoreDevice but cannot currently acquire an install/debug tunnel.", file=sys.stderr)
    sys.exit(1)

if require_wireless and not wireless_ready:
    print("Device is usable, but not over wireless transport right now.", file=sys.stderr)
    print("Unplug USB-C, keep the iPhone unlocked, and keep Mac and iPhone on the same Wi-Fi with IPv6.", file=sys.stderr)
    sys.exit(3)
PY
