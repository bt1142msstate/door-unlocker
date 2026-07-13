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
ACTIVATION_JOURNAL_ADDRESS="0x000E9000"
OTA_MEMORY_LAYOUT_HEADER="$ROOT_DIR/firmware/DoorUnlockerXiao/OtaMemoryLayout.h"
ATT_MTU_BYTES="247"
MAX_DFU_PAYLOAD_BYTES="244"
GAP_EVENT_LENGTH_UNITS="12"
MIN_CONNECTION_INTERVAL_MS="${DOOR_BOOTLOADER_MIN_CONNECTION_INTERVAL_MS:-15}"
MAX_CONNECTION_INTERVAL_MS="${DOOR_BOOTLOADER_MAX_CONNECTION_INTERVAL_MS:-15}"
FLASH_LOCAL_LATENCY_EVENTS="${DOOR_BOOTLOADER_FLASH_LOCAL_LATENCY:-50}"
PHY_PREFERENCE="${DOOR_BOOTLOADER_PHY_PREFERENCE:-auto}"
HCI_RX_QUEUE_SIZE="${DOOR_BOOTLOADER_HCI_RX_QUEUE_SIZE:-16}"
PSTORAGE_QUEUE_SIZE="${DOOR_BOOTLOADER_PSTORAGE_QUEUE_SIZE:-18}"
BUILD_PROFILE="${DOOR_BOOTLOADER_BUILD_PROFILE:-release-candidate}"
CANDIDATE_DFU_DEVICE_NAME="DoorDFU"
DEFAULT_TO_OTA_DFU="ON"
KEY_DIR="${DOOR_FIRMWARE_SIGNING_DIR:-$HOME/Library/Application Support/Door Unlocker/FirmwareSigning}"
KEY_PATH="${DOOR_FIRMWARE_SIGNING_KEY:-$KEY_DIR/firmware-signing-key.pem}"
PROFILE_SLUG="$(printf '%s' "$BUILD_PROFILE" | tr -c 'A-Za-z0-9._-' '-')"
WORK_DIR="${DOOR_BOOTLOADER_WORK_DIR:-${TMPDIR:-/tmp}/door-unlocker-secure-bootloader-${PROFILE_SLUG}}"
SOURCE_DIR="$WORK_DIR/source"
BUILD_DIR="$WORK_DIR/build"
VENV_DIR="$WORK_DIR/venv"
if [[ "$BUILD_PROFILE" == "release-candidate" ]]; then
  OUTPUT_DIR="${DOOR_BOOTLOADER_OUTPUT_DIR:-$ROOT_DIR/dist/bootloader}"
  RELEASE_DIR="${DOOR_BOOTLOADER_RELEASE_DIR:-$ROOT_DIR/bootloader/releases}"
  PUBLIC_MANIFEST="${DOOR_BOOTLOADER_PUBLIC_MANIFEST:-$ROOT_DIR/docs/firmware-signing-public-key.json}"
else
  OUTPUT_DIR="${DOOR_BOOTLOADER_OUTPUT_DIR:-$ROOT_DIR/dist/bootloader/variants/$PROFILE_SLUG}"
  RELEASE_DIR="${DOOR_BOOTLOADER_RELEASE_DIR:-$OUTPUT_DIR/releases}"
  PUBLIC_MANIFEST="${DOOR_BOOTLOADER_PUBLIC_MANIFEST:-$OUTPUT_DIR/manifest.json}"
fi
PUBLIC_KEY_PEM="$ROOT_DIR/docs/firmware-signing-public-key.pem"
TRANSACTIONAL_ACTIVATION_DIR="$ROOT_DIR/bootloader/transactional_activation"
BOOTLOADER_PATCHER="$ROOT_DIR/script/patch_secure_bootloader.py"
ARM_GCC_DIR="${ARM_GCC_DIR:-$HOME/Library/Arduino15/packages/Seeeduino/tools/arm-none-eabi-gcc/9-2019q4/bin}"
GENERATE_KEY=0

case "$PHY_PREFERENCE" in
  auto) PHY_SOURCE_CONSTANT="BLE_GAP_PHY_AUTO" ;;
  2m) PHY_SOURCE_CONSTANT="BLE_GAP_PHY_2MBPS" ;;
  *) echo "DOOR_BOOTLOADER_PHY_PREFERENCE must be auto or 2m." >&2; exit 2 ;;
esac
if ! [[ "$FLASH_LOCAL_LATENCY_EVENTS" =~ ^[0-9]+$ ]] || (( FLASH_LOCAL_LATENCY_EVENTS > 50 )); then
  echo "DOOR_BOOTLOADER_FLASH_LOCAL_LATENCY must be an integer from 0 through 50." >&2
  exit 2
fi
if ! [[ "$HCI_RX_QUEUE_SIZE" =~ ^[0-9]+$ ]] || (( HCI_RX_QUEUE_SIZE < 8 || (HCI_RX_QUEUE_SIZE & (HCI_RX_QUEUE_SIZE - 1)) != 0 )); then
  echo "DOOR_BOOTLOADER_HCI_RX_QUEUE_SIZE must be a power of two of at least 8." >&2
  exit 2
fi
if ! [[ "$PSTORAGE_QUEUE_SIZE" =~ ^[0-9]+$ ]] || (( PSTORAGE_QUEUE_SIZE < HCI_RX_QUEUE_SIZE + 2 )); then
  echo "DOOR_BOOTLOADER_PSTORAGE_QUEUE_SIZE must exceed the BLE queue by at least two." >&2
  exit 2
fi
if [[ "$MIN_CONNECTION_INTERVAL_MS" != "15" && "$MIN_CONNECTION_INTERVAL_MS" != "30" ]] \
  || [[ "$MAX_CONNECTION_INTERVAL_MS" != "15" && "$MAX_CONNECTION_INTERVAL_MS" != "30" ]] \
  || (( MIN_CONNECTION_INTERVAL_MS > MAX_CONNECTION_INTERVAL_MS )); then
  echo "Door Unlocker's BLE interval must be 15 or 30 ms with min <= max." >&2
  exit 2
fi

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

# Upstream DEFAULT_TO_OTA_DFU also redirects an intentional double-reset to BLE.
# Keep automatic invalid-app BLE recovery without sacrificing the USB UF2 escape hatch.
BOOTLOADER_MAIN_SOURCE="$SOURCE_DIR/src/main.c"
SOURCE_PATH="$BOOTLOADER_MAIN_SOURCE" /usr/bin/python3 <<'PY'
import os
from pathlib import Path

path = Path(os.environ["SOURCE_PATH"])
source = path.read_text(encoding="utf-8")
old = """  if (!valid_app || dfu_start) {
    _ota_dfu = 1;
  }
"""
new = """  if (!valid_app && !dfu_start) {
    _ota_dfu = 1;
  }
"""
if source.count(old) != 1:
    raise SystemExit("Could not uniquely preserve double-reset USB recovery")
path.write_text(source.replace(old, new), encoding="utf-8")
PY

/usr/bin/python3 "$BOOTLOADER_PATCHER" \
  --source "$SOURCE_DIR" \
  --module "$TRANSACTIONAL_ACTIVATION_DIR" \
  --flash-local-latency "$FLASH_LOCAL_LATENCY_EVENTS" \
  --phy-mode "$PHY_PREFERENCE" \
  --hci-rx-queue-size "$HCI_RX_QUEUE_SIZE" \
  --pstorage-queue-size "$PSTORAGE_QUEUE_SIZE" \
  --minimum-connection-interval-ms "$MIN_CONNECTION_INTERVAL_MS" \
  --maximum-connection-interval-ms "$MAX_CONNECTION_INTERVAL_MS"

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
require_source_marker "$SOURCE_DIR/src/main.c" ".rx_phys = $PHY_SOURCE_CONSTANT"
require_source_marker "$SOURCE_DIR/src/sdk_config.h" "#define HCI_RX_BUF_QUEUE_SIZE              $HCI_RX_QUEUE_SIZE"
require_source_marker "$SOURCE_DIR/src/pstorage_platform.h" "#define PSTORAGE_CMD_QUEUE_SIZE     $PSTORAGE_QUEUE_SIZE"
require_source_marker "$SOURCE_DIR/lib/sdk11/components/ble/ble_services/ble_dfu/ble_dfu.c" \
  "#define MAX_DFU_PKT_LEN                 (BLEGATT_ATT_MTU_MAX - 3)"
require_source_marker "$SOURCE_DIR/lib/sdk11/components/libraries/bootloader_dfu/dfu_transport_ble.c" \
  "#define MIN_CONN_INTERVAL                    (uint16_t)(MSEC_TO_UNITS($MIN_CONNECTION_INTERVAL_MS, UNIT_1_25_MS))"
require_source_marker "$SOURCE_DIR/lib/sdk11/components/libraries/bootloader_dfu/dfu_transport_ble.c" \
  "#define MAX_CONN_INTERVAL                    (uint16_t)(MSEC_TO_UNITS($MAX_CONNECTION_INTERVAL_MS, UNIT_1_25_MS))"
require_source_marker "$SOURCE_DIR/lib/sdk11/components/libraries/bootloader_dfu/dfu_transport_ble.c" \
  "#define SPEEDUP_FLASH_WRITES                 1"
require_source_marker "$SOURCE_DIR/lib/sdk11/components/libraries/bootloader_dfu/dfu_transport_ble.c" \
  "requested_latency = $FLASH_LOCAL_LATENCY_EVENTS;"
require_source_marker "$SOURCE_DIR/lib/sdk11/components/libraries/bootloader_dfu/dfu_transport_ble.c" \
  "BLE_GAP_EVT_DATA_LENGTH_UPDATE_REQUEST"
require_source_marker "$SOURCE_DIR/CMakeLists.txt" \
  'option(DUALBANK_FW "Enable dual bank DFU support" OFF)'
require_source_marker "$SOURCE_DIR/CMakeLists.txt" \
  '${SDK11_DIR}/libraries/bootloader_dfu/dfu_dual_bank.c'
require_source_marker "$SOURCE_DIR/lib/sdk11/components/libraries/bootloader_dfu/dfu_dual_bank.c" \
  'mp_storage_handle_active = &m_storage_handle_swap;'
require_source_marker "$SOURCE_DIR/lib/sdk11/components/libraries/bootloader_dfu/dfu_dual_bank.c" \
  'if (m_image_size > DFU_IMAGE_MAX_SIZE_BANKED)'
require_source_marker "$SOURCE_DIR/lib/sdk11/components/libraries/bootloader_dfu/dfu_dual_bank.c" \
  'm_functions.prepare = dfu_prepare_func_swap_erase;'
require_source_marker "$SOURCE_DIR/src/door_activation_journal.c" \
  'flash_nrf5x_erase(DFU_BANK_0_REGION_START, image_size);'
require_source_marker "$SOURCE_DIR/src/door_activation_journal.c" \
  'NRF_POWER->GPREGRET = 0;'
require_source_marker "$SOURCE_DIR/lib/sdk11/components/libraries/bootloader_dfu/dfu_dual_bank.c" \
  'return door_activation_stage(m_start_packet.app_image_size, m_image_crc);'
require_source_marker "$SOURCE_DIR/lib/sdk11/components/libraries/bootloader_dfu/dfu_dual_bank.c" \
  'if (dfu_region_is_erased(DFU_BANK_1_REGION_START, image_size))'

grep -Fqx "constexpr uint32_t OTA_APPLICATION_START = $APPLICATION_START_ADDRESS;" \
  "$OTA_MEMORY_LAYOUT_HEADER" || {
  echo "Application staging layout drifted from the bootloader build." >&2
  exit 1
}
grep -Fqx "constexpr uint32_t OTA_DUAL_BANK_APPLICATION_BYTES = $DUAL_BANK_APPLICATION_MAX_BYTES;" \
  "$OTA_MEMORY_LAYOUT_HEADER" || {
  echo "Application staging size drifted from the bootloader build." >&2
  exit 1
}

export PATH="$ARM_GCC_DIR:$PATH"
pushd "$SOURCE_DIR" >/dev/null
cmake -S "$SOURCE_DIR" -B "$BUILD_DIR" \
  -DBOARD="$BOARD" \
  -DSD_VERSION="$SOFTDEVICE_VERSION" \
  -DDUALBANK_FW=ON \
  -DDEFAULT_TO_OTA_DFU="$DEFAULT_TO_OTA_DFU" \
  -DSIGNED_FW=ON \
  -DSIGNED_FW_QX="$QX" \
  -DSIGNED_FW_QY="$QY" \
  -DPython_EXECUTABLE="$VENV_DIR/bin/python3"
DFU_TRANSPORT_SOURCE="$SOURCE_DIR/lib/sdk11/components/libraries/bootloader_dfu/dfu_transport_ble.c"
SOURCE_PATH="$DFU_TRANSPORT_SOURCE" DEVICE_NAME="$CANDIDATE_DFU_DEVICE_NAME" /usr/bin/python3 <<'PY'
import os
from pathlib import Path

path = Path(os.environ["SOURCE_PATH"])
source = path.read_text(encoding="utf-8")
old = '#define DEVICE_NAME                          "AdaDFU"'
new = f'#define DEVICE_NAME                          "{os.environ["DEVICE_NAME"]}"'
if source.count(old) != 1:
    raise SystemExit("Could not uniquely replace the upstream DFU device name")
path.write_text(source.replace(old, new), encoding="utf-8")
PY
cmake --build "$BUILD_DIR" --parallel
popd >/dev/null

grep -Fqx 'DUALBANK_FW:BOOL=ON' "$BUILD_DIR/CMakeCache.txt" || {
  echo "Built bootloader did not retain DUALBANK_FW=ON." >&2
  exit 1
}
grep -Fq 'dfu_dual_bank.c.obj' "$BUILD_DIR/CMakeFiles/bootloader.dir/link.txt" || {
  echo "Built bootloader does not link the dual-bank implementation." >&2
  exit 1
}
if grep -Fq 'dfu_single_bank.c.obj' "$BUILD_DIR/CMakeFiles/bootloader.dir/link.txt"; then
  echo "Built bootloader unexpectedly links the single-bank implementation." >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
BOOTLOADER_HEX="$OUTPUT_DIR/DoorUnlocker-XIAO-Sense-${BOOTLOADER_VERSION}-signed-dualbank.hex"
BOOTLOADER_UF2="$OUTPUT_DIR/DoorUnlocker-XIAO-Sense-${BOOTLOADER_VERSION}-signed-dualbank-migration.uf2"
BOOTLOADER_CODE_BIN="$OUTPUT_DIR/DoorUnlocker-XIAO-Sense-${BOOTLOADER_VERSION}-transactional-code.bin"
BOOTLOADER_DFU_PACKAGE="$OUTPUT_DIR/DoorUnlocker-XIAO-Sense-${BOOTLOADER_VERSION}-transactional-bootloader-dfu.zip"
BOOTLOADER_DFU_RELEASE="$RELEASE_DIR/$(basename "$BOOTLOADER_DFU_PACKAGE")"
cp -X "$BUILD_DIR/bootloader_mbr.hex" "$BOOTLOADER_HEX"
cp -X "$BUILD_DIR/bootloader_mbr.uf2" "$BOOTLOADER_UF2"

BOOTLOADER_HEX="$BOOTLOADER_HEX" \
BOOTLOADER_CODE_BIN="$BOOTLOADER_CODE_BIN" \
BOOTLOADER_START_ADDRESS="$BOOTLOADER_START_ADDRESS" \
BOOTLOADER_SETTINGS_ADDRESS="0xFD800" \
"$VENV_DIR/bin/python3" <<'PY'
import os
from pathlib import Path

from intelhex import IntelHex

source = IntelHex(os.environ["BOOTLOADER_HEX"])
bootloader_start = int(os.environ["BOOTLOADER_START_ADDRESS"], 0)
settings_start = int(os.environ["BOOTLOADER_SETTINGS_ADDRESS"], 0)
code_segments = [
    (start, end)
    for start, end in source.segments()
    if bootloader_start <= start < settings_start and end <= settings_start
]
if len(code_segments) != 1 or code_segments[0][0] != bootloader_start:
    raise SystemExit(f"Expected one contiguous bootloader code segment, got {code_segments}")
start, end = code_segments[0]
Path(os.environ["BOOTLOADER_CODE_BIN"]).write_bytes(
    bytes(source[address] for address in range(start, end))
)
PY

if [[ -f "$KEY_PATH" ]]; then
  "$VENV_DIR/bin/python3" "$ROOT_DIR/script/build_signed_dfu_package.py" \
    --image-type bootloader \
    --input "$BOOTLOADER_CODE_BIN" \
    --output "$BOOTLOADER_DFU_PACKAGE" \
    --device-type 0x0052 \
    --device-revision 52840 \
    --softdevice-request "$SOFTDEVICE_FIRMWARE_ID" \
    --key "$KEY_PATH"
  mkdir -p "$RELEASE_DIR"
  cp -X "$BOOTLOADER_DFU_PACKAGE" "$BOOTLOADER_DFU_RELEASE"
elif [[ -f "$BOOTLOADER_DFU_RELEASE" ]]; then
  cp -X "$BOOTLOADER_DFU_RELEASE" "$BOOTLOADER_DFU_PACKAGE"
else
  rm -f "$BOOTLOADER_DFU_PACKAGE"
fi

PUBLIC_KEY_ID="$PUBLIC_KEY_ID" \
BOOTLOADER_HEX="$BOOTLOADER_HEX" \
BOOTLOADER_UF2="$BOOTLOADER_UF2" \
BOOTLOADER_CODE_BIN="$BOOTLOADER_CODE_BIN" \
BOOTLOADER_DFU_PACKAGE="$BOOTLOADER_DFU_PACKAGE" \
BOOTLOADER_VERSION="$BOOTLOADER_VERSION" \
BOARD="$BOARD" \
SOFTDEVICE_VERSION="$SOFTDEVICE_VERSION" \
SOFTDEVICE_FIRMWARE_ID="$SOFTDEVICE_FIRMWARE_ID" \
APPLICATION_START_ADDRESS="$APPLICATION_START_ADDRESS" \
BOOTLOADER_START_ADDRESS="$BOOTLOADER_START_ADDRESS" \
RESERVED_APPLICATION_DATA_BYTES="$RESERVED_APPLICATION_DATA_BYTES" \
DUAL_BANK_APPLICATION_MAX_BYTES="$DUAL_BANK_APPLICATION_MAX_BYTES" \
ACTIVATION_JOURNAL_ADDRESS="$ACTIVATION_JOURNAL_ADDRESS" \
ATT_MTU_BYTES="$ATT_MTU_BYTES" \
MAX_DFU_PAYLOAD_BYTES="$MAX_DFU_PAYLOAD_BYTES" \
GAP_EVENT_LENGTH_UNITS="$GAP_EVENT_LENGTH_UNITS" \
MIN_CONNECTION_INTERVAL_MS="$MIN_CONNECTION_INTERVAL_MS" \
MAX_CONNECTION_INTERVAL_MS="$MAX_CONNECTION_INTERVAL_MS" \
FLASH_LOCAL_LATENCY_EVENTS="$FLASH_LOCAL_LATENCY_EVENTS" \
PHY_PREFERENCE="$PHY_PREFERENCE" \
HCI_RX_QUEUE_SIZE="$HCI_RX_QUEUE_SIZE" \
PSTORAGE_QUEUE_SIZE="$PSTORAGE_QUEUE_SIZE" \
BUILD_PROFILE="$BUILD_PROFILE" \
CANDIDATE_DFU_DEVICE_NAME="$CANDIDATE_DFU_DEVICE_NAME" \
DEFAULT_TO_OTA_DFU="$DEFAULT_TO_OTA_DFU" \
PUBLIC_MANIFEST="$PUBLIC_MANIFEST" \
/usr/bin/python3 <<'PY'
import hashlib
import json
import os
import struct
from pathlib import Path

artifact = Path(os.environ["BOOTLOADER_HEX"])
migration_artifact = Path(os.environ["BOOTLOADER_UF2"])
code_artifact = Path(os.environ["BOOTLOADER_CODE_BIN"])
ota_artifact = Path(os.environ["BOOTLOADER_DFU_PACKAGE"])

application_start = int(os.environ["APPLICATION_START_ADDRESS"], 0)
bootloader_start = int(os.environ["BOOTLOADER_START_ADDRESS"], 0)
reserved_bytes = int(os.environ["RESERVED_APPLICATION_DATA_BYTES"])
dual_bank_bytes = int(os.environ["DUAL_BANK_APPLICATION_MAX_BYTES"])
journal_address = int(os.environ["ACTIVATION_JOURNAL_ADDRESS"], 0)
if journal_address != application_start + 2 * dual_bank_bytes:
    raise SystemExit("Activation journal is not immediately after bank 1")
if journal_address + 4096 > bootloader_start - reserved_bytes:
    raise SystemExit("Activation journal overlaps reserved application data")

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
    "flashWriteLocalLatencyEvents": int(os.environ["FLASH_LOCAL_LATENCY_EVENTS"]),
    "phyPreference": os.environ["PHY_PREFERENCE"],
    "hciRxQueueSize": int(os.environ["HCI_RX_QUEUE_SIZE"]),
    "pstorageQueueSize": int(os.environ["PSTORAGE_QUEUE_SIZE"]),
    "buildProfile": os.environ["BUILD_PROFILE"],
    "dfuDeviceName": os.environ["CANDIDATE_DFU_DEVICE_NAME"],
    "defaultToOtaDfu": os.environ["DEFAULT_TO_OTA_DFU"] == "ON",
    "invalidAppDefaultsToOtaDfu": True,
    "doubleResetUsbRecoveryPreserved": True,
    "dataLengthExtension": True,
    "automaticTwoMegabitPhy": True,
    "flashWritePacing": True,
    "verifiedBlankBankEraseBypass": True,
    "backgroundInactiveBankPreparation": True,
    "dualBankFirmware": True,
    "singleBankFallbackDisabled": True,
    "interruptedTransferRetainsBank0": True,
    "activationPowerLossRequiresPhysicalProof": True,
    "transactionalActivationJournal": True,
    "activationJournalAddress": f"0x{journal_address:08X}",
    "activationResumesAfterReset": True,
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
    "bootloaderCodeArtifact": code_artifact.name,
    "bootloaderCodeArtifactBytes": code_artifact.stat().st_size,
    "bootloaderCodeArtifactSha256": hashlib.sha256(code_artifact.read_bytes()).hexdigest(),
    "otaBootloaderArtifact": ota_artifact.name if ota_artifact.is_file() else None,
    "otaBootloaderArtifactBytes": ota_artifact.stat().st_size if ota_artifact.is_file() else None,
    "otaBootloaderArtifactSha256": (
        hashlib.sha256(ota_artifact.read_bytes()).hexdigest()
        if ota_artifact.is_file()
        else None
    ),
}
Path(os.environ["PUBLIC_MANIFEST"]).write_text(
    json.dumps(manifest, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PY

echo "Secure bootloader: $BOOTLOADER_HEX"
echo "One-time UF2 migration artifact: $BOOTLOADER_UF2"
echo "OTA bootloader code image: $BOOTLOADER_CODE_BIN"
if [[ -f "$BOOTLOADER_DFU_PACKAGE" ]]; then
  echo "Signed OTA bootloader package: $BOOTLOADER_DFU_PACKAGE"
fi
echo "Public build manifest: $PUBLIC_MANIFEST"
echo "Public verification key: $PUBLIC_KEY_PEM"
if [[ -f "$KEY_PATH" ]]; then
  echo "Private signing key (not in Git): $KEY_PATH"
else
  echo "Bootloader reproduced from checked-in public key; no private key was required."
fi
