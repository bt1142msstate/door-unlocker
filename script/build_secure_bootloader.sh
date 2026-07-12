#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOOTLOADER_VERSION="0.11.0"
BOOTLOADER_REPOSITORY="https://github.com/adafruit/Adafruit_nRF52_Bootloader.git"
BOARD="xiao_nrf52840_ble_sense"
SOFTDEVICE_VERSION="7.3.0"
SOFTDEVICE_FIRMWARE_ID="0x0123"
APPLICATION_START_ADDRESS="0x27000"
BOOTLOADER_START_ADDRESS="0xF4000"
RESERVED_APPLICATION_DATA_BYTES="40960"
DUAL_BANK_APPLICATION_MAX_BYTES="397312"
KEY_DIR="${DOOR_FIRMWARE_SIGNING_DIR:-$HOME/Library/Application Support/Door Unlocker/FirmwareSigning}"
KEY_PATH="${DOOR_FIRMWARE_SIGNING_KEY:-$KEY_DIR/firmware-signing-key.pem}"
WORK_DIR="${DOOR_BOOTLOADER_WORK_DIR:-${TMPDIR:-/tmp}/door-unlocker-secure-bootloader}"
SOURCE_DIR="$WORK_DIR/source"
BUILD_DIR="$WORK_DIR/build"
VENV_DIR="$WORK_DIR/venv"
OUTPUT_DIR="$ROOT_DIR/dist/bootloader"
PUBLIC_MANIFEST="$ROOT_DIR/docs/firmware-signing-public-key.json"
PUBLIC_KEY_PEM="$ROOT_DIR/docs/firmware-signing-public-key.pem"
ARM_GCC_DIR="${ARM_GCC_DIR:-$HOME/Library/Arduino15/packages/Seeeduino/tools/arm-none-eabi-gcc/9-2019q4/bin}"
GENERATE_KEY=0

if [[ "${1:-}" == "--generate-key" ]]; then
  GENERATE_KEY=1
elif [[ $# -gt 0 ]]; then
  echo "usage: $0 [--generate-key]" >&2
  exit 2
fi

if [[ ! -x "$ARM_GCC_DIR/arm-none-eabi-gcc" ]]; then
  echo "ARM GCC was not found at $ARM_GCC_DIR." >&2
  exit 1
fi

mkdir -p "$KEY_DIR"
chmod 700 "$KEY_DIR"
if [[ ! -f "$KEY_PATH" ]]; then
  if [[ "$GENERATE_KEY" != "1" ]]; then
    echo "Firmware signing key is missing: $KEY_PATH" >&2
    echo "Run once with --generate-key, then back up that private key securely." >&2
    exit 1
  fi
  openssl ecparam -name prime256v1 -genkey -noout -out "$KEY_PATH"
fi
chmod 600 "$KEY_PATH"

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
git clone --depth 1 --branch "$BOOTLOADER_VERSION" "$BOOTLOADER_REPOSITORY" "$SOURCE_DIR"
git -C "$SOURCE_DIR" submodule update --init lib/nrfx lib/tinycrypt lib/tinyusb lib/uf2

/usr/bin/python3 -m venv "$VENV_DIR"
"$VENV_DIR/bin/pip" install --quiet "ecdsa==0.19.1" "intelhex==2.3.0"

key_values="$($VENV_DIR/bin/python3 - "$KEY_PATH" <<'PY'
from pathlib import Path
from ecdsa import SigningKey
import hashlib
import sys

raw = SigningKey.from_pem(Path(sys.argv[1]).read_text()).get_verifying_key().to_string()
print(','.join(f'0x{byte:02x}' for byte in raw[:32]))
print(','.join(f'0x{byte:02x}' for byte in raw[32:]))
print(hashlib.sha256(raw).hexdigest())
PY
)"
QX="$(printf '%s\n' "$key_values" | sed -n '1p')"
QY="$(printf '%s\n' "$key_values" | sed -n '2p')"
PUBLIC_KEY_ID="$(printf '%s\n' "$key_values" | sed -n '3p')"
"$VENV_DIR/bin/python3" - "$KEY_PATH" "$PUBLIC_KEY_PEM" <<'PY'
from pathlib import Path
from ecdsa import SigningKey
import sys

key = SigningKey.from_pem(Path(sys.argv[1]).read_text())
Path(sys.argv[2]).write_bytes(key.get_verifying_key().to_pem())
PY

export PATH="$ARM_GCC_DIR:$PATH"
pushd "$SOURCE_DIR" >/dev/null
cmake -S "$SOURCE_DIR" -B "$BUILD_DIR" \
  -DBOARD="$BOARD" \
  -DSD_VERSION="$SOFTDEVICE_VERSION" \
  -DDUALBANK_FW=ON \
  -DSIGNED_FW=ON \
  -DSIGNED_FW_QX="$QX" \
  -DSIGNED_FW_QY="$QY" \
  -DPython_EXECUTABLE="$VENV_DIR/bin/python3"
cmake --build "$BUILD_DIR" --parallel
popd >/dev/null

mkdir -p "$OUTPUT_DIR"
BOOTLOADER_HEX="$OUTPUT_DIR/DoorUnlocker-XIAO-Sense-${BOOTLOADER_VERSION}-signed-dualbank.hex"
BOOTLOADER_UF2="$OUTPUT_DIR/DoorUnlocker-XIAO-Sense-${BOOTLOADER_VERSION}-signed-dualbank-migration.uf2"
cp -X "$BUILD_DIR/bootloader_mbr.hex" "$BOOTLOADER_HEX"
cp -X "$BUILD_DIR/bootloader_mbr.uf2" "$BOOTLOADER_UF2"

PUBLIC_KEY_ID="$PUBLIC_KEY_ID" \
BOOTLOADER_HEX="$BOOTLOADER_HEX" \
BOOTLOADER_UF2="$BOOTLOADER_UF2" \
BOOTLOADER_VERSION="$BOOTLOADER_VERSION" \
BOARD="$BOARD" \
SOFTDEVICE_VERSION="$SOFTDEVICE_VERSION" \
SOFTDEVICE_FIRMWARE_ID="$SOFTDEVICE_FIRMWARE_ID" \
APPLICATION_START_ADDRESS="$APPLICATION_START_ADDRESS" \
BOOTLOADER_START_ADDRESS="$BOOTLOADER_START_ADDRESS" \
RESERVED_APPLICATION_DATA_BYTES="$RESERVED_APPLICATION_DATA_BYTES" \
DUAL_BANK_APPLICATION_MAX_BYTES="$DUAL_BANK_APPLICATION_MAX_BYTES" \
PUBLIC_MANIFEST="$PUBLIC_MANIFEST" \
/usr/bin/python3 <<'PY'
import hashlib
import json
import os
from pathlib import Path

artifact = Path(os.environ["BOOTLOADER_HEX"])
migration_artifact = Path(os.environ["BOOTLOADER_UF2"])
manifest = {
    "board": os.environ["BOARD"],
    "bootloaderVersion": os.environ["BOOTLOADER_VERSION"],
    "softDeviceVersion": os.environ["SOFTDEVICE_VERSION"],
    "softDeviceFirmwareId": os.environ["SOFTDEVICE_FIRMWARE_ID"],
    "applicationStartAddress": os.environ["APPLICATION_START_ADDRESS"],
    "bootloaderStartAddress": os.environ["BOOTLOADER_START_ADDRESS"],
    "reservedApplicationDataBytes": int(os.environ["RESERVED_APPLICATION_DATA_BYTES"]),
    "dualBankApplicationMaxBytes": int(os.environ["DUAL_BANK_APPLICATION_MAX_BYTES"]),
    "dualBankFirmware": True,
    "signedFirmwareRequired": True,
    "forceUnsignedUF2": False,
    "publicKeyId": os.environ["PUBLIC_KEY_ID"],
    "artifact": artifact.name,
    "artifactSha256": hashlib.sha256(artifact.read_bytes()).hexdigest(),
    "migrationArtifact": migration_artifact.name,
    "migrationArtifactSha256": hashlib.sha256(migration_artifact.read_bytes()).hexdigest(),
}
Path(os.environ["PUBLIC_MANIFEST"]).write_text(
    json.dumps(manifest, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PY

echo "Secure bootloader: $BOOTLOADER_HEX"
echo "One-time UF2 migration artifact: $BOOTLOADER_UF2"
echo "Public build manifest: $PUBLIC_MANIFEST"
echo "Public verification key: $PUBLIC_KEY_PEM"
echo "Private signing key (not in Git): $KEY_PATH"
