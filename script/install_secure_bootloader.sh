#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOOTLOADER_VERSION="0.11.0"
MIGRATION_UF2="$ROOT_DIR/dist/bootloader/DoorUnlocker-XIAO-Sense-${BOOTLOADER_VERSION}-signed-dualbank-migration.uf2"
BOOTLOADER_VOLUME="${BOOTLOADER_VOLUME:-/Volumes/XIAO-SENSE}"
CONFIRM_RECOVERY=0
ACCEPT_NO_RECOVERY_RISK=0
INSTALL=0

usage() {
  cat <<'USAGE'
usage: script/install_secure_bootloader.sh [--install (--confirm-jlink-recovery | --accept-no-swd-recovery-risk)]

Without --install, rebuilds and validates the signed dual-bank candidate only.
Installation is a one-time bootloader migration, not a normal firmware update.
It requires an attended XIAO UF2 volume and a tested J-Link/SWD recovery path.

Options:
  --install                   Copy the migration UF2 to /Volumes/XIAO-SENSE.
  --confirm-jlink-recovery    Confirm that J-Link/SWD unbrick recovery is available.
  --accept-no-swd-recovery-risk
                              Explicitly accept that a failed migration may
                              require replacing the controller.
  --volume PATH               Override the mounted XIAO UF2 volume.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install) INSTALL=1 ;;
    --confirm-jlink-recovery) CONFIRM_RECOVERY=1 ;;
    --accept-no-swd-recovery-risk) ACCEPT_NO_RECOVERY_RISK=1 ;;
    --volume)
      shift
      BOOTLOADER_VOLUME="${1:-}"
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

"$ROOT_DIR/script/build_secure_bootloader.sh"
python3 "$ROOT_DIR/script/check_ota_bootloader_contract.py" --require-candidate

if [[ "$INSTALL" != "1" ]]; then
  echo "Candidate prepared only; no controller was modified."
  exit 0
fi

if [[ "$CONFIRM_RECOVERY" != "1" && "$ACCEPT_NO_RECOVERY_RISK" != "1" ]]; then
  echo "Refusing bootloader migration without a recovery confirmation or explicit risk acceptance." >&2
  echo "Use --confirm-jlink-recovery, or --accept-no-swd-recovery-risk only when replacement is acceptable." >&2
  exit 1
fi

if [[ "$ACCEPT_NO_RECOVERY_RISK" == "1" ]]; then
  echo "WARNING: proceeding without SWD recovery. A failed bootloader migration may require controller replacement." >&2
fi

if [[ ! -d "$BOOTLOADER_VOLUME" || ! -f "$BOOTLOADER_VOLUME/INFO_UF2.TXT" ]]; then
  "$ROOT_DIR/script/physical_handoff.sh" --preset reset-twice >/dev/null
  deadline=$(( $(date +%s) + 30 ))
  while [[ ! -f "$BOOTLOADER_VOLUME/INFO_UF2.TXT" && $(date +%s) -lt $deadline ]]; do
    sleep 1
  done
  if [[ ! -f "$BOOTLOADER_VOLUME/INFO_UF2.TXT" ]]; then
    echo "XIAO UF2 volume did not appear at $BOOTLOADER_VOLUME." >&2
    exit 1
  fi
fi

if [[ ! -f "$MIGRATION_UF2" ]]; then
  echo "Migration artifact is missing: $MIGRATION_UF2" >&2
  exit 1
fi

echo "Installing signed dual-bank bootloader $BOOTLOADER_VERSION. Do not remove power."
cp -X "$MIGRATION_UF2" "$BOOTLOADER_VOLUME/"
sync
echo "Migration file copied. Verify normal firmware, signed OTA, and unsigned rejection before recording proof."
