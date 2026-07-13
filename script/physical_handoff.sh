#!/usr/bin/env bash
set -euo pipefail

MODE="auto"
PRESET="custom"
TITLE="Physical test step"
INSTRUCTION="Complete the requested physical step when prompted."
SPOKEN_PRELUDE="Prepare for the physical test step."
SPOKEN_ACTION="Complete the physical step now."
CONFIRMATION="Complete the physical step, then continue."
CONFIRM_LABEL="Done"
COUNTDOWN=3
SYMBOL="wrench.and.screwdriver.fill"
ACCENT="blue"
DRY_RUN=0
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_DIR="$ROOT_DIR/tools/DoorUnlockerHandoff"

usage() {
  cat <<'USAGE'
usage: script/physical_handoff.sh [options]

Shows a blocking native macOS handoff dialog, speaks an optional countdown,
then returns only after the operator confirms that the physical step is done.
The caller can continue automatically when this process exits successfully.

Options:
  --mode auto|gui|terminal
  --preset custom|power-cycle-battery|connect-usb|return-to-battery|reset-once|reset-twice
  --title TEXT
  --instruction TEXT
  --spoken-prelude TEXT
  --spoken-action TEXT
  --confirmation TEXT
  --confirm-label TEXT
  --countdown SECONDS
  --symbol SF_SYMBOL_NAME
  --accent blue|green|orange|pink
  --dry-run
USAGE
}

apply_preset() {
  case "$1" in
    custom) ;;
    power-cycle-battery)
      TITLE="Power-cycle the controller"
      INSTRUCTION="Click Start countdown when you are ready to disconnect controller power."
      SPOKEN_PRELUDE="Prepare to disconnect the door unlocker battery."
      SPOKEN_ACTION="Disconnect now. Wait at least two seconds, then reconnect the battery."
      CONFIRMATION="Disconnect the battery, wait at least two seconds, and reconnect it. Confirm only after the controller is powered again."
      CONFIRM_LABEL="Power restored"
      COUNTDOWN=3
      SYMBOL="battery.0percent"
      ACCENT="orange"
      ;;
    connect-usb)
      TITLE="Connect the controller over USB-C"
      INSTRUCTION="The test is paused until the controller is connected directly to this Mac."
      SPOKEN_PRELUDE="I need you to connect the door unlocker controller to the Mac with USB C."
      SPOKEN_ACTION=""
      CONFIRMATION="Connect USB-C and wait for the controller light to turn on, then confirm."
      CONFIRM_LABEL="USB-C connected"
      COUNTDOWN=0
      SYMBOL="cable.connector"
      ACCENT="blue"
      ;;
    return-to-battery)
      TITLE="Return the controller to battery power"
      INSTRUCTION="USB-C is no longer needed. Disconnect it and reconnect the controller battery."
      SPOKEN_PRELUDE="Disconnect USB C and reconnect the door unlocker battery."
      SPOKEN_ACTION=""
      CONFIRMATION="Confirm after USB-C is disconnected and the controller is running from its battery."
      CONFIRM_LABEL="Running on battery"
      COUNTDOWN=0
      SYMBOL="battery.100percent"
      ACCENT="green"
      ;;
    reset-once)
      TITLE="Reset the controller once"
      INSTRUCTION="Press the small reset button on the XIAO one time."
      SPOKEN_PRELUDE="Press the door unlocker controller reset button once."
      SPOKEN_ACTION=""
      CONFIRMATION="Confirm after you have pressed the reset button exactly once."
      CONFIRM_LABEL="Reset pressed"
      COUNTDOWN=0
      SYMBOL="button.programmable"
      ACCENT="orange"
      ;;
    reset-twice)
      TITLE="Enter controller bootloader mode"
      INSTRUCTION="Quickly press the small XIAO reset button twice."
      SPOKEN_PRELUDE="Quickly press the door unlocker controller reset button twice."
      SPOKEN_ACTION=""
      CONFIRMATION="Confirm after the two quick presses and the controller light changes."
      CONFIRM_LABEL="Pressed twice"
      COUNTDOWN=0
      SYMBOL="button.programmable.square"
      ACCENT="pink"
      ;;
    *)
      echo "Unknown physical handoff preset: $1" >&2
      exit 2
      ;;
  esac
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) shift; MODE="${1:-}" ;;
    --preset) shift; PRESET="${1:-}"; apply_preset "$PRESET" ;;
    --title) shift; TITLE="${1:-}" ;;
    --instruction) shift; INSTRUCTION="${1:-}" ;;
    --spoken-prelude) shift; SPOKEN_PRELUDE="${1:-}" ;;
    --spoken-action) shift; SPOKEN_ACTION="${1:-}" ;;
    --confirmation) shift; CONFIRMATION="${1:-}" ;;
    --confirm-label) shift; CONFIRM_LABEL="${1:-}" ;;
    --countdown) shift; COUNTDOWN="${1:-}" ;;
    --symbol) shift; SYMBOL="${1:-}" ;;
    --accent) shift; ACCENT="${1:-}" ;;
    --dry-run) DRY_RUN=1 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if [[ "$MODE" != "auto" && "$MODE" != "gui" && "$MODE" != "terminal" ]]; then
  echo "--mode must be auto, gui, or terminal." >&2
  exit 2
fi
if [[ ! "$COUNTDOWN" =~ ^[0-9]+$ ]] || (( COUNTDOWN > 10 )); then
  echo "--countdown must be an integer from 0 through 10." >&2
  exit 2
fi
if [[ "$ACCENT" != "blue" && "$ACCENT" != "green" && "$ACCENT" != "orange" && "$ACCENT" != "pink" ]]; then
  echo "--accent must be blue, green, orange, or pink." >&2
  exit 2
fi

if [[ "$DRY_RUN" == "1" ]]; then
  printf 'mode=%s\npreset=%s\ntitle=%s\ninstruction=%s\ncountdown=%s\nconfirmation=%s\nconfirm_label=%s\n' \
    "$MODE" "$PRESET" "$TITLE" "$INSTRUCTION" "$COUNTDOWN" "$CONFIRMATION" "$CONFIRM_LABEL"
  exit 0
fi

gui_available() {
  command -v swift >/dev/null 2>&1 &&
    launchctl print "gui/$(id -u)" >/dev/null 2>&1
}

run_gui_handoff() {
  swift build --package-path "$PACKAGE_DIR" -c release --product door-unlocker-handoff >/dev/null
  "$PACKAGE_DIR/.build/release/door-unlocker-handoff" \
    --title "$TITLE" \
    --instruction "$INSTRUCTION" \
    --spoken-prelude "$SPOKEN_PRELUDE" \
    --spoken-action "$SPOKEN_ACTION" \
    --confirmation "$CONFIRMATION" \
    --confirm-label "$CONFIRM_LABEL" \
    --countdown "$COUNTDOWN" \
    --symbol "$SYMBOL" \
    --accent "$ACCENT"
}

run_terminal_handoff() {
  if [[ ! -t 0 ]]; then
    echo "Physical handoff requires a macOS GUI session or an interactive terminal." >&2
    return 2
  fi
  printf '\n%s\n%s\n' "$TITLE" "$INSTRUCTION"
  read -r -p "Press Return to start the countdown... "
  if command -v say >/dev/null 2>&1 && [[ -n "$SPOKEN_PRELUDE" ]]; then
    say "$SPOKEN_PRELUDE"
  fi
  local remaining
  for ((remaining = COUNTDOWN; remaining >= 1; remaining--)); do
    if command -v say >/dev/null 2>&1; then say "$remaining"; else printf '%s\n' "$remaining"; fi
    sleep 1
  done
  if command -v say >/dev/null 2>&1 && [[ -n "$SPOKEN_ACTION" ]]; then
    say "$SPOKEN_ACTION"
  fi
  printf '%s\n' "$CONFIRMATION"
  read -r -p "Press Return when complete... "
}

case "$MODE" in
  gui)
    if ! gui_available; then
      echo "A macOS GUI session is not available." >&2
      exit 2
    fi
    run_gui_handoff
    ;;
  terminal) run_terminal_handoff ;;
  auto)
    if gui_available; then run_gui_handoff; else run_terminal_handoff; fi
    ;;
esac
