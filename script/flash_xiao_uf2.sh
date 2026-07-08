#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKETCH_DIR="$ROOT_DIR/firmware/DoorUnlockerXiao"
TMP_SKETCH="${TMPDIR:-/tmp}/DoorUnlockerXiao"
TMP_BUILD="${TMPDIR:-/tmp}/DoorUnlockerXiaoBuild"
UF2_PATH="$TMP_SKETCH/DoorUnlockerXiao.uf2"
DIST_UF2_PATH="$ROOT_DIR/dist/DoorUnlockerXiao.uf2"
DFU_ZIP_PATH="$TMP_BUILD/DoorUnlockerXiao.ino.zip"
DIST_DFU_ZIP_PATH="$ROOT_DIR/dist/DoorUnlockerXiao-dfu.zip"
FQBN="${XIAO_FQBN:-Seeeduino:nrf52:xiaonRF52840Sense}"
XIAO_OPTIMIZATION_FLAG="${XIAO_OPTIMIZATION_FLAG:--Os}"
UF2CONV="${UF2CONV:-$HOME/Library/Arduino15/packages/Seeeduino/hardware/nrf52/1.1.13/tools/uf2conv/uf2conv.py}"
NRFUTIL="${NRFUTIL:-$HOME/Library/Arduino15/packages/Seeeduino/hardware/nrf52/1.1.13/tools/adafruit-nrfutil/macos/adafruit-nrfutil}"
DFU_DEVICE_TYPE="${DFU_DEVICE_TYPE:-0x0052}"
DFU_SOFTDEVICE_REQ="${DFU_SOFTDEVICE_REQ:-0x0123}"
XIAO_VOLUME="${XIAO_VOLUME:-/Volumes/XIAO-SENSE}"
PORT="${DOOR_UNLOCKER_PORT:-}"
BUILD_ONLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)
      shift
      PORT="${1:-}"
      ;;
    --build-only)
      BUILD_ONLY=1
      ;;
    --help|-h)
      cat <<'USAGE'
usage: script/flash_xiao_uf2.sh [--port /dev/cu.usbmodemXXXX] [--build-only]

Compiles the XIAO firmware, asks the running controller to enter UF2 bootloader
mode when supported, then copies the UF2 to /Volumes/XIAO-SENSE.

If the currently installed firmware does not support the bootloader command yet,
double-press the XIAO reset button when prompted.

Use --build-only to create dist/DoorUnlockerXiao.uf2 and
dist/DoorUnlockerXiao-dfu.zip without trying to flash.

Set XIAO_OPTIMIZATION_FLAG=-Ofast to reproduce the stock Seeed build size.
USAGE
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
  shift
done

discover_usb_port() {
  if [[ -n "$PORT" ]]; then
    printf '%s\n' "$PORT"
    return
  fi

  local discovered
  discovered="$(ls -1 /dev/cu.usbmodem* 2>/dev/null | head -n 1 || true)"
  printf '%s\n' "$discovered"
}

close_admin_app_for_serial_recovery() {
  osascript -e 'tell application "DoorUnlockerAdmin" to quit' >/dev/null 2>&1 || true
  pkill -x DoorUnlockerAdmin >/dev/null 2>&1 || true
  sleep 1
}

try_serial_dfu_recovery() {
  local serial_port
  serial_port="$(discover_usb_port)"
  if [[ -z "$serial_port" || ! -e "$serial_port" ]]; then
    return 1
  fi

  echo "Trying serial DFU recovery on $serial_port..."
  close_admin_app_for_serial_recovery
  if "$NRFUTIL" dfu serial -pkg "$DIST_DFU_ZIP_PATH" -p "$serial_port" -b 115200; then
    echo "Serial DFU recovery complete."
    return 0
  fi

  echo "Serial DFU did not answer; trying 1200-baud bootloader touch..."
  if "$NRFUTIL" dfu serial -pkg "$DIST_DFU_ZIP_PATH" -p "$serial_port" -b 115200 -t 1200; then
    echo "Serial DFU recovery complete."
    return 0
  fi

  return 1
}

rm -rf "$TMP_SKETCH" "$TMP_BUILD"
mkdir -p "$TMP_SKETCH"
rsync -a "$SKETCH_DIR/" "$TMP_SKETCH/"

echo "Compiling XIAO firmware..."
arduino-cli compile \
  --fqbn "$FQBN" \
  --build-property "compiler.optimization_flag=$XIAO_OPTIMIZATION_FLAG" \
  --build-path "$TMP_BUILD" \
  "$TMP_SKETCH"

echo "Creating UF2..."
python3 "$UF2CONV" -f 0xADA52840 -c -o "$UF2_PATH" "$TMP_BUILD/DoorUnlockerXiao.ino.hex"
mkdir -p "$(dirname "$DIST_UF2_PATH")"
cp -X "$UF2_PATH" "$DIST_UF2_PATH"
echo "UF2 ready at $DIST_UF2_PATH"

echo "Creating BLE DFU package..."
"$NRFUTIL" dfu genpkg \
  --dev-type "$DFU_DEVICE_TYPE" \
  --sd-req "$DFU_SOFTDEVICE_REQ" \
  --application "$TMP_BUILD/DoorUnlockerXiao.ino.hex" \
  "$DFU_ZIP_PATH"
cp -X "$DFU_ZIP_PATH" "$DIST_DFU_ZIP_PATH"
echo "BLE DFU package ready at $DIST_DFU_ZIP_PATH"

if [[ "$BUILD_ONLY" == "1" ]]; then
  exit 0
fi

if [[ ! -d "$XIAO_VOLUME" ]]; then
  echo "Requesting UF2 bootloader mode over USB-C..."
  (
    cd "$ROOT_DIR/mac/DoorUnlockerAdmin"
    swift build --product door-unlocker >/dev/null
  )

  CLI="$ROOT_DIR/mac/DoorUnlockerAdmin/.build/debug/door-unlocker"
  if [[ -n "$PORT" ]]; then
    "$CLI" --port "$PORT" bootloader || true
  else
    "$CLI" bootloader || true
  fi
fi

deadline=$(( $(date +%s) + 20 ))
while [[ ! -d "$XIAO_VOLUME" && $(date +%s) -lt $deadline ]]; do
  sleep 1
done

if [[ ! -d "$XIAO_VOLUME" ]]; then
  echo "The XIAO is not in UF2 bootloader mode yet." >&2
  echo "Double-press reset now, then leave the board plugged in." >&2
  deadline=$(( $(date +%s) + 60 ))
  while [[ ! -d "$XIAO_VOLUME" && $(date +%s) -lt $deadline ]]; do
    sleep 1
  done
fi

if [[ ! -d "$XIAO_VOLUME" ]]; then
  echo "Timed out waiting for $XIAO_VOLUME." >&2
  if try_serial_dfu_recovery; then
    exit 0
  fi
  exit 1
fi

echo "Copying UF2 to $XIAO_VOLUME..."
cp -X "$UF2_PATH" "$XIAO_VOLUME/"
sync
echo "Flash complete."
