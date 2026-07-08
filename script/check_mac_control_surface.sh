#!/usr/bin/env bash
set -euo pipefail

APP_NAME="DoorUnlockerAdmin"
APP_PATH="${HOME}/Applications/${APP_NAME}.app"
TRACE_FILE="${HOME}/Library/Application Support/DoorUnlockerAdmin/startup-timing.log"

if [[ ! -d "${APP_PATH}" ]]; then
  echo "DoorUnlockerAdmin.app is not installed at ${APP_PATH}" >&2
  echo "Run ./script/build_and_run.sh --install first." >&2
  exit 1
fi

open -a "${APP_PATH}"
sleep 1.5

if ! /usr/bin/osascript <<'APPLESCRIPT'
tell application "System Events"
  if not (exists process "DoorUnlockerAdmin") then error "DoorUnlockerAdmin process is not running"
  tell process "DoorUnlockerAdmin"
    set frontmost to true
    set matchingButtons to {}
    repeat with candidate in buttons of window 1
      set candidateTitle to ""
      try
        set candidateTitle to name of candidate as text
      end try
      if candidateTitle contains "Click to lock" or candidateTitle contains "Click to unlock" then
        set end of matchingButtons to candidate
      end if
    end repeat
    if (count of matchingButtons) is 0 then error "No enabled lock/unlock control surface was found"
    click item 1 of matchingButtons
  end tell
end tell
APPLESCRIPT
then
  echo "Could not click the Mac control surface. Enable Accessibility permission for the terminal/Codex app, or make sure the controller is connected and ready." >&2
  exit 1
fi

sleep 1

if [[ -f "${TRACE_FILE}" ]]; then
  echo "Recent Mac runtime telemetry:"
  tail -n 20 "${TRACE_FILE}"
else
  echo "Clicked Mac control surface. Runtime telemetry file not found yet: ${TRACE_FILE}"
fi
