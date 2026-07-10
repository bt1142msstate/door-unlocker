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
    if (count of windows) is 0 then
      try
        click menu item "Show Door Unlocker" of menu "File" of menu bar item "File" of menu bar 1
      on error
        try
          click menu item "Door Unlocker" of menu "Window" of menu bar item "Window" of menu bar 1
        end try
      end try
      delay 1
    end if
    repeat 40 times
      repeat with candidate in menu items of menu "Controller" of menu bar item "Controller" of menu bar 1
        set candidateTitle to name of candidate as text
        if (candidateTitle is "Lock" or candidateTitle is "Unlock") and (enabled of candidate) then
          click candidate
          return
        end if
      end repeat
      delay 0.25
    end repeat
    error "No enabled lock/unlock control path was found after 10 seconds"
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
