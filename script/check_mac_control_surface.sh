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

trace_start_line=0
if [[ -f "${TRACE_FILE}" ]]; then
  trace_start_line="$(wc -l < "${TRACE_FILE}" | tr -d ' ')"
fi

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

if [[ ! -f "${TRACE_FILE}" ]]; then
  echo "Clicked Mac control surface. Runtime telemetry file was not created: ${TRACE_FILE}" >&2
  exit 1
fi

python3 - "${TRACE_FILE}" "${trace_start_line}" <<'PY'
import re
import sys
import time
from pathlib import Path

trace_path = Path(sys.argv[1])
start_line = int(sys.argv[2])
deadline = time.monotonic() + 8
event_pattern = re.compile(r"DUMacStartup\s+(\d+)ms\s+(.+)$")
requested = sent = confirmed = None
command = None

while time.monotonic() < deadline:
    lines = trace_path.read_text(encoding="utf-8", errors="replace").splitlines()[start_line:]
    for line in lines:
        match = event_pattern.search(line)
        if not match:
            continue
        timestamp_ms = int(match.group(1))
        event = match.group(2)
        if requested is None and event.startswith("door_command_requested "):
            command = event.rsplit(" ", 1)[-1]
            requested = timestamp_ms
        elif command and sent is None and event == f"wireless_command_sent {command}":
            sent = timestamp_ms
        elif command and event.startswith(f"door_command_confirmed {command} "):
            confirmed = timestamp_ms
            break
    if requested is not None and sent is not None and confirmed is not None:
        break
    time.sleep(0.05)

if requested is None:
    raise SystemExit("Mac UI test did not record a door command request")
if sent is None:
    raise SystemExit(f"Mac UI test did not send {command} over Bluetooth")
if confirmed is None:
    raise SystemExit(f"Controller did not confirm {command} within 8 seconds")

request_to_write = sent - requested
request_to_confirmation = confirmed - requested
write_to_confirmation = confirmed - sent
print(f"command={command}")
print(f"request_to_write_ms={request_to_write}")
print(f"write_to_confirmation_ms={write_to_confirmation}")
print(f"request_to_confirmation_ms={request_to_confirmation}")
if request_to_confirmation > 2_500:
    raise SystemExit(f"Mac UI command confirmation was too slow: {request_to_confirmation} ms")
PY

echo "Recent Mac runtime telemetry:"
tail -n 24 "${TRACE_FILE}"
