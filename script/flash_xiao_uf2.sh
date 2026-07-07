#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKETCH_DIR="$ROOT_DIR/firmware/DoorUnlockerXiao"
TMP_SKETCH="${TMPDIR:-/tmp}/DoorUnlockerXiao"
TMP_BUILD="${TMPDIR:-/tmp}/DoorUnlockerXiaoBuild"
UF2_PATH="$TMP_SKETCH/DoorUnlockerXiao.uf2"
FQBN="${XIAO_FQBN:-Seeeduino:nrf52:xiaonRF52840Sense}"
UF2CONV="${UF2CONV:-$HOME/Library/Arduino15/packages/Seeeduino/hardware/nrf52/1.1.13/tools/uf2conv/uf2conv.py}"
XIAO_VOLUME="${XIAO_VOLUME:-/Volumes/XIAO-SENSE}"
PORT="${DOOR_UNLOCKER_PORT:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)
      shift
      PORT="${1:-}"
      ;;
    --help|-h)
      cat <<'USAGE'
usage: script/flash_xiao_uf2.sh [--port /dev/cu.usbmodemXXXX]

Compiles the XIAO firmware, asks the running controller to enter UF2 bootloader
mode when supported, then copies the UF2 to /Volumes/XIAO-SENSE.

If the currently installed firmware does not support the bootloader command yet,
double-press the XIAO reset button when prompted.
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

rm -rf "$TMP_SKETCH" "$TMP_BUILD"
mkdir -p "$TMP_SKETCH"
rsync -a "$SKETCH_DIR/" "$TMP_SKETCH/"

echo "Compiling XIAO firmware..."
arduino-cli compile --fqbn "$FQBN" --build-path "$TMP_BUILD" "$TMP_SKETCH"

echo "Creating UF2..."
python3 "$UF2CONV" -f 0xADA52840 -c -o "$UF2_PATH" "$TMP_BUILD/DoorUnlockerXiao.ino.hex"

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
  exit 1
fi

echo "Copying UF2 to $XIAO_VOLUME..."
cp -X "$UF2_PATH" "$XIAO_VOLUME/"
sync
echo "Flash complete."
