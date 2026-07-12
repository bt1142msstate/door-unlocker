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
ATT_MTU_BYTES="247"
MAX_DFU_PAYLOAD_BYTES="244"
GAP_EVENT_LENGTH_UNITS="12"
MIN_CONNECTION_INTERVAL_MS="15"
MAX_CONNECTION_INTERVAL_MS="30"
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
if [[ "$GENERATE_KEY" == "1" && ! -f "$KEY_PATH" ]]; then
  openssl ecparam -name prime256v1 -genkey -noout -out "$KEY_PATH"
fi
if [[ -f "$KEY_PATH" ]]; then
  chmod 600 "$KEY_PATH"
elif [[ ! -f "$PUBLIC_KEY_PEM" ]]; then
  echo "Neither the private signing key nor checked-in public key exists." >&2
  echo "Run once with --generate-key, then back up the private key securely." >&2
  exit 1
fi

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
/usr/bin/python3 -m venv "$VENV_DIR"
"$VENV_DIR/bin/pip" install --quiet "ecdsa==0.19.1" "intelhex==2.3.0"

key_values="$($VENV_DIR/bin/python3 - "$KEY_PATH" "$PUBLIC_KEY_PEM" <<'PY'
from pathlib import Path
from ecdsa import SigningKey, VerifyingKey
import hashlib
import sys

private_key = Path(sys.argv[1])
public_key = Path(sys.argv[2])
if private_key.is_file():
    verifying_key = SigningKey.from_pem(private_key.read_text()).get_verifying_key()
    if public_key.is_file():
        recorded_key = VerifyingKey.from_pem(public_key.read_text())
        if recorded_key.to_string() != verifying_key.to_string():
            raise SystemExit("Private signing key does not match the checked-in public key")
    else:
        public_key.write_bytes(verifying_key.to_pem())
else:
    verifying_key = VerifyingKey.from_pem(public_key.read_text())
raw = verifying_key.to_string()
print(','.join(f'0x{byte:02x}' for byte in raw[:32]))
print(','.join(f'0x{byte:02x}' for byte in raw[32:]))
print(hashlib.sha256(raw).hexdigest())
PY
)"
QX="$(printf '%s\n' "$key_values" | sed -n '1p')"
QY="$(printf '%s\n' "$key_values" | sed -n '2p')"
PUBLIC_KEY_ID="$(printf '%s\n' "$key_values" | sed -n '3p')"
git clone --depth 1 --branch "$BOOTLOADER_VERSION" "$BOOTLOADER_REPOSITORY" "$SOURCE_DIR"
git -C "$SOURCE_DIR" submodule update --init lib/nrfx lib/tinycrypt lib/tinyusb lib/uf2

require_source_marker() {
  local file="$1"
  local marker="$2"
  if ! grep -Fq "$marker" "$file"; then
    echo "Bootloader speed/safety capability missing from $file: $marker" >&2
    exit 1
  fi
}

require_source_marker "$SOURCE_DIR/src/sdk_config.h" "#define BLEGATT_ATT_MTU_MAX         $ATT_MTU_BYTES"
require_source_marker "$SOURCE_DIR/src/main.c" "#define BLEGAP_EVENT_LENGTH             $GAP_EVENT_LENGTH_UNITS"
require_source_marker "$SOURCE_DIR/src/main.c" "opt.common_opt.conn_evt_ext.enable = 1"
require_source_marker "$SOURCE_DIR/src/main.c" ".rx_phys = BLE_GAP_PHY_AUTO"
require_source_marker "$SOURCE_DIR/lib/sdk11/components/ble/ble_services/ble_dfu/ble_dfu.c" \
  "#define MAX_DFU_PKT_LEN                 (BLEGATT_ATT_MTU_MAX - 3)"
require_source_marker "$SOURCE_DIR/lib/sdk11/components/libraries/bootloader_dfu/dfu_transport_ble.c" \
  "#define MIN_CONN_INTERVAL                    (uint16_t)(MSEC_TO_UNITS($MIN_CONNECTION_INTERVAL_MS, UNIT_1_25_MS))"
require_source_marker "$SOURCE_DIR/lib/sdk11/components/libraries/bootloader_dfu/dfu_transport_ble.c" \
  "#define MAX_CONN_INTERVAL                    (uint16_t)(MSEC_TO_UNITS($MAX_CONNECTION_INTERVAL_MS, UNIT_1_25_MS))"
require_source_marker "$SOURCE_DIR/lib/sdk11/components/libraries/bootloader_dfu/dfu_transport_ble.c" \
  "#define SPEEDUP_FLASH_WRITES                 1"
require_source_marker "$SOURCE_DIR/lib/sdk11/components/libraries/bootloader_dfu/dfu_transport_ble.c" \
  "BLE_GAP_EVT_DATA_LENGTH_UPDATE_REQUEST"

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
ATT_MTU_BYTES="$ATT_MTU_BYTES" \
MAX_DFU_PAYLOAD_BYTES="$MAX_DFU_PAYLOAD_BYTES" \
GAP_EVENT_LENGTH_UNITS="$GAP_EVENT_LENGTH_UNITS" \
MIN_CONNECTION_INTERVAL_MS="$MIN_CONNECTION_INTERVAL_MS" \
MAX_CONNECTION_INTERVAL_MS="$MAX_CONNECTION_INTERVAL_MS" \
PUBLIC_MANIFEST="$PUBLIC_MANIFEST" \
/usr/bin/python3 <<'PY'
import hashlib
import json
import os
import struct
from pathlib import Path

artifact = Path(os.environ["BOOTLOADER_HEX"])
migration_artifact = Path(os.environ["BOOTLOADER_UF2"])

blocks = []
raw_uf2 = migration_artifact.read_bytes()
if len(raw_uf2) == 0 or len(raw_uf2) % 512 != 0:
    raise SystemExit("Migration UF2 has an invalid byte length")
for offset in range(0, len(raw_uf2), 512):
    block = raw_uf2[offset:offset + 512]
    magic0, magic1, flags, address, size, number, total, family = struct.unpack_from(
        "<IIIIIIII", block, 0
    )
    magic_end = struct.unpack_from("<I", block, 508)[0]
    if (magic0, magic1, magic_end) != (0x0A324655, 0x9E5D5157, 0x0AB16F30):
        raise SystemExit(f"Migration UF2 block {number} has invalid magic")
    blocks.append((address, address + size, flags, family, number, total))

ordered = sorted(blocks)
ranges = []
range_start = range_end = None
for start, end, *_ in ordered:
    if range_start is None:
        range_start, range_end = start, end
    elif start == range_end:
        range_end = end
    else:
        ranges.append((range_start, range_end))
        range_start, range_end = start, end
ranges.append((range_start, range_end))

manifest = {
    "board": os.environ["BOARD"],
    "bootloaderVersion": os.environ["BOOTLOADER_VERSION"],
    "softDeviceVersion": os.environ["SOFTDEVICE_VERSION"],
    "softDeviceFirmwareId": os.environ["SOFTDEVICE_FIRMWARE_ID"],
    "applicationStartAddress": os.environ["APPLICATION_START_ADDRESS"],
    "bootloaderStartAddress": os.environ["BOOTLOADER_START_ADDRESS"],
    "reservedApplicationDataBytes": int(os.environ["RESERVED_APPLICATION_DATA_BYTES"]),
    "dualBankApplicationMaxBytes": int(os.environ["DUAL_BANK_APPLICATION_MAX_BYTES"]),
    "attMtuBytes": int(os.environ["ATT_MTU_BYTES"]),
    "maxDfuPayloadBytes": int(os.environ["MAX_DFU_PAYLOAD_BYTES"]),
    "gapEventLengthUnits": int(os.environ["GAP_EVENT_LENGTH_UNITS"]),
    "minimumConnectionIntervalMs": int(os.environ["MIN_CONNECTION_INTERVAL_MS"]),
    "maximumConnectionIntervalMs": int(os.environ["MAX_CONNECTION_INTERVAL_MS"]),
    "dataLengthExtension": True,
    "automaticTwoMegabitPhy": True,
    "flashWritePacing": True,
    "dualBankFirmware": True,
    "signedFirmwareRequired": True,
    "forceUnsignedUF2": False,
    "publicKeyId": os.environ["PUBLIC_KEY_ID"],
    "artifact": artifact.name,
    "artifactSha256": hashlib.sha256(artifact.read_bytes()).hexdigest(),
    "migrationArtifact": migration_artifact.name,
    "migrationArtifactSha256": hashlib.sha256(migration_artifact.read_bytes()).hexdigest(),
    "migrationBlockCount": len(blocks),
    "migrationFamilyId": f"0x{blocks[0][3]:08X}",
    "migrationAddressRanges": [
        {
            "start": f"0x{start:08X}",
            "endExclusive": f"0x{end:08X}",
            "bytes": end - start,
        }
        for start, end in ranges
    ],
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
if [[ -f "$KEY_PATH" ]]; then
  echo "Private signing key (not in Git): $KEY_PATH"
else
  echo "Bootloader reproduced from checked-in public key; no private key was required."
fi
