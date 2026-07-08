#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_FIRMWARE="${TARGET_FIRMWARE:-}"
DEVICE_UDID="${DEVICE_UDID:-}"
POLL_SECONDS="${POLL_SECONDS:-420}"
RUNS="${RUNS:-3}"
DRY_RUN=0
STOP_ON_FAILURE=0
BASE_RUN_ID="${RUN_ID:-$(date -u +"%Y%m%dT%H%M%SZ")}"
OUTPUT_DIR="${OTA_BENCHMARK_DIR:-$ROOT_DIR/docs/ota-benchmarks/$BASE_RUN_ID}"
CASES=()

usage() {
  cat <<USAGE
usage: script/benchmark_ios_ota_matrix.sh [--target VERSION] [--device-udid UDID] [--runs N] [--case NAME=PRN:DELAY] [--dry-run] [--stop-on-failure]

Runs repeatable iPhone wireless-only OTA DFU proofs for a small tuning matrix.
Each case delegates to script/verify_ios_ota.sh, which installs the iPhone app,
refuses to run if the controller USB-C serial port is visible, uploads the
bundled DFU package over BLE, and verifies the post-update firmware version
over BLE.

Defaults:
  --runs 3
  --case stable=8:0.4
  --case faster-object-prep=8:0.3
  --case reliability-check=4:0.3

Environment:
  TARGET_FIRMWARE      Firmware version to verify. Defaults to firmware source.
  DEVICE_UDID          Physical iOS device UDID. Auto-detected by verifier when omitted.
  POLL_SECONDS         Per-run verifier timeout. Defaults to 420.
  RUN_ID               Benchmark batch id. Defaults to UTC timestamp.
  OTA_BENCHMARK_DIR    Output directory. Defaults to docs/ota-benchmarks/<RUN_ID>.
USAGE
}

slugify() {
  printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C tr -c '[:alnum:]._-' '-'
}

default_target_firmware() {
  sed -n 's/.*CONTROLLER_FIRMWARE_VERSION\[\] = "\([^"]*\)".*/\1/p' \
    "$ROOT_DIR/firmware/DoorUnlockerXiao/DoorUnlockerXiao.ino" |
    head -n 1
}

add_case() {
  local spec="$1"
  if [[ "$spec" != *=* || "$spec" != *:* ]]; then
    echo "Invalid case '$spec'. Expected NAME=PRN:DELAY, for example stable=8:0.4." >&2
    exit 2
  fi
  CASES+=("$spec")
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)
      shift
      TARGET_FIRMWARE="${1:-}"
      ;;
    --device-udid)
      shift
      DEVICE_UDID="${1:-}"
      ;;
    --runs)
      shift
      RUNS="${1:-}"
      ;;
    --case)
      shift
      add_case "${1:-}"
      ;;
    --dry-run)
      DRY_RUN=1
      ;;
    --stop-on-failure)
      STOP_ON_FAILURE=1
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

if [[ -z "$TARGET_FIRMWARE" ]]; then
  TARGET_FIRMWARE="$(default_target_firmware)"
fi

if [[ -z "$TARGET_FIRMWARE" ]]; then
  echo "Could not determine target firmware version." >&2
  exit 1
fi

if ! [[ "$RUNS" =~ ^[0-9]+$ ]] || [[ "$RUNS" -lt 1 ]]; then
  echo "--runs must be a positive integer." >&2
  exit 2
fi

if [[ "${#CASES[@]}" -eq 0 ]]; then
  CASES=("stable=8:0.4" "faster-object-prep=8:0.3" "reliability-check=4:0.3")
fi

mkdir -p "$OUTPUT_DIR"

echo "OTA benchmark batch: $BASE_RUN_ID"
echo "Target firmware: $TARGET_FIRMWARE"
echo "Runs per case: $RUNS"
echo "Output: $OUTPUT_DIR"

declare -a REPORTS=()
declare -i failures=0

for case_spec in "${CASES[@]}"; do
  case_name="${case_spec%%=*}"
  tuning="${case_spec#*=}"
  prn="${tuning%%:*}"
  delay="${tuning#*:}"
  case_slug="$(slugify "$case_name")"

  for run_index in $(seq 1 "$RUNS"); do
    run_id="${BASE_RUN_ID}-${case_slug}-r${run_index}"
    report_path="$OUTPUT_DIR/${case_slug}-r${run_index}.json"
    REPORTS+=("$report_path")

    cmd=(
      "$ROOT_DIR/script/verify_ios_ota.sh"
      "--wireless-only"
      "--target"
      "$TARGET_FIRMWARE"
    )
    if [[ -n "$DEVICE_UDID" ]]; then
      cmd+=("--device-udid" "$DEVICE_UDID")
    fi

    echo
    echo "==> $case_name run $run_index/$RUNS: PRN=$prn objectDelay=$delay"
    echo "RUN_ID=$run_id OTA_REPORT_PATH=$report_path DFU_PRN=$prn DFU_OBJECT_PREP_DELAY=$delay POLL_SECONDS=$POLL_SECONDS ${cmd[*]}"

    if [[ "$DRY_RUN" == "1" ]]; then
      continue
    fi

    if RUN_ID="$run_id" \
      OTA_REPORT_PATH="$report_path" \
      DFU_PRN="$prn" \
      DFU_OBJECT_PREP_DELAY="$delay" \
      POLL_SECONDS="$POLL_SECONDS" \
      "${cmd[@]}"; then
      :
    else
      failures+=1
      if [[ "$STOP_ON_FAILURE" == "1" ]]; then
        break 2
      fi
    fi
  done
done

if [[ "$DRY_RUN" == "1" ]]; then
  echo
  echo "Dry run complete; no OTA updates were started."
  exit 0
fi

set +e
"$ROOT_DIR/script/summarize_ota_benchmark.py" \
  --run-id "$BASE_RUN_ID" \
  --target "$TARGET_FIRMWARE" \
  --output-dir "$OUTPUT_DIR" \
  --latest "$ROOT_DIR/docs/ota-benchmark-last-run.json" \
  "${REPORTS[@]}"
summary_exit=$?
set -e

if [[ "$summary_exit" -ne 0 && "$failures" -eq 0 ]]; then
  failures="$summary_exit"
fi

exit "$failures"
