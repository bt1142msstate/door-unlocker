#!/usr/bin/env python3
"""Alternate real iPhone and Mac BLE commands and verify both subscribers converge."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import queue
import re
import statistics
import subprocess
import threading
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MAC_TRACE = Path.home() / "Library/Application Support/DoorUnlockerAdmin/startup-timing.log"
REPORT = ROOT / "docs/mixed-client-stress-last-run.json"
BUNDLE_ID = "io.github.bt1142msstate.DoorUnlocker"
DEVELOPER_DIR = "/Applications/Xcode.app/Contents/Developer"
MAC_EVENT = re.compile(r"DUMacStartup\s+(\d+)ms\s+(.+)$")
IOS_EVENT = re.compile(r"DUStartup\s+(\d+)ms\s+(.+)$")


class IOSConsole:
    def __init__(self, device: str) -> None:
        self.device = device
        self.lines: list[str] = []
        self._line_queue: queue.Queue[str] = queue.Queue()
        self._process: subprocess.Popen[str] | None = None
        self._thread: threading.Thread | None = None

    def start(self) -> None:
        env = os.environ.copy()
        env["DEVELOPER_DIR"] = DEVELOPER_DIR
        # A detached devicectl console can outlive its host briefly. Terminate
        # explicitly so the next cold launch attaches to exactly one process.
        subprocess.run(
            [
                "/usr/bin/xcrun", "devicectl", "device", "process", "terminate",
                "--device", self.device, BUNDLE_ID,
            ],
            cwd=ROOT,
            env=env,
            check=False,
            capture_output=True,
            text=True,
        )
        time.sleep(0.3)
        self._process = subprocess.Popen(
            [
                "/usr/bin/xcrun",
                "devicectl",
                "device",
                "process",
                "launch",
                "--device",
                self.device,
                "--terminate-existing",
                "--console",
                BUNDLE_ID,
            ],
            cwd=ROOT,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            bufsize=1,
        )
        self._thread = threading.Thread(target=self._read_lines, daemon=True)
        self._thread.start()

    def _read_lines(self) -> None:
        assert self._process is not None and self._process.stdout is not None
        for raw_line in self._process.stdout:
            line = raw_line.rstrip("\r\n")
            self.lines.append(line)
            self._line_queue.put(line)

    def wait_for(self, predicate, start_index: int = 0, timeout: float = 8) -> tuple[int, str]:
        deadline = time.monotonic() + timeout
        inspected = start_index
        while time.monotonic() < deadline:
            while inspected < len(self.lines):
                line = self.lines[inspected]
                inspected += 1
                if predicate(line):
                    return inspected - 1, line
            try:
                self._line_queue.get(timeout=min(0.05, max(0.001, deadline - time.monotonic())))
            except queue.Empty:
                pass
        raise RuntimeError("Timed out waiting for iPhone telemetry")

    def stop(self) -> None:
        if self._process is None:
            return
        self._process.terminate()
        try:
            self._process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self._process.kill()


def device_identifier() -> str:
    result = subprocess.run(
        [str(ROOT / "script/ios_device_status.sh"), "--json"],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
    )
    status = json.loads(result.stdout)
    if not status.get("usable"):
        raise RuntimeError(f"iPhone is not available: {status}")
    return str(status["identifier"])


def mac_lines() -> list[str]:
    if not MAC_TRACE.exists():
        return []
    return MAC_TRACE.read_text(encoding="utf-8", errors="replace").splitlines()


def wait_for_mac_event(start_line: int, predicate, timeout: float = 8) -> tuple[int, str]:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        for line in mac_lines()[start_line:]:
            match = MAC_EVENT.search(line)
            if match and predicate(match.group(2)):
                return int(match.group(1)), match.group(2)
        time.sleep(0.02)
    raise RuntimeError("Timed out waiting for Mac telemetry")


def launch_iphone_command(device: str, command: str) -> int:
    env = os.environ.copy()
    env["DEVELOPER_DIR"] = DEVELOPER_DIR
    started = time.monotonic()
    subprocess.run(
        [
            "/usr/bin/xcrun",
            "devicectl",
            "device",
            "process",
            "launch",
            "--device",
            device,
            "--payload-url",
            f"doorunlocker://debug-{command.lower()}",
            BUNDLE_ID,
        ],
        cwd=ROOT,
        env=env,
        check=True,
        capture_output=True,
        text=True,
    )
    return round((time.monotonic() - started) * 1000)


def click_mac_door_command() -> None:
    script = r'''
tell application "System Events"
  tell process "DoorUnlockerAdmin"
    set frontmost to true
    repeat 40 times
      repeat with candidate in menu items of menu "Controller" of menu bar item "Controller" of menu bar 1
        set candidateTitle to name of candidate as text
        if (candidateTitle is "Lock" or candidateTitle is "Unlock") and (enabled of candidate) then
          click candidate
          return
        end if
      end repeat
      delay 0.05
    end repeat
    error "No enabled Mac lock/unlock action"
  end tell
end tell
'''
    subprocess.run(["/usr/bin/osascript", "-e", script], check=True, capture_output=True, text=True)


def ios_event(line: str) -> tuple[int, str] | None:
    match = IOS_EVENT.search(line)
    if not match:
        return None
    return int(match.group(1)), match.group(2)


def summary(values: list[int]) -> dict[str, float | int]:
    ordered = sorted(values)
    p95_index = min(len(ordered) - 1, max(0, int(len(ordered) * 0.95) - 1))
    return {
        "minimum": min(values),
        "median": round(statistics.median(values), 1),
        "mean": round(statistics.mean(values), 1),
        "p95": ordered[p95_index],
        "maximum": max(values),
    }


def initial_command_from_state(line: str) -> str:
    event = ios_event(line)
    if event is None or not event[1].startswith("door_state_received "):
        raise RuntimeError(f"Invalid initial door-state telemetry: {line}")
    state = event[1].removeprefix("door_state_received ")
    if state == "locked":
        return "UNLOCK"
    if state == "unlocked" or state.startswith("unlocked:"):
        return "LOCK"
    raise RuntimeError(f"Controller did not reach a stable initial state: {state}")


def write_report(
    *,
    results: list[dict[str, int | str]],
    expected_count: int,
    max_confirm_ms: int,
    failure: str | None,
    diagnostics: list[str],
) -> None:
    latencies = [int(result["requestToConfirmationMs"]) for result in results]
    subscribers_verified = len(results) == expected_count
    passed = (
        failure is None
        and subscribers_verified
        and bool(latencies)
        and max(latencies) <= max_confirm_ms
    )
    report: dict[str, object] = {
        "generatedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
        "passed": passed,
        "commandCount": len(results),
        "expectedCommandCount": expected_count,
        "origins": sorted({str(result["origin"]) for result in results}),
        "crossSubscriberConfirmationCount": len(results),
        "simultaneousSubscribersVerified": subscribers_verified,
        "maximumAllowedConfirmationMs": max_confirm_ms,
        "commands": results,
        "failure": failure,
        "diagnostics": diagnostics[-80:],
    }
    if latencies:
        report["requestToConfirmationMs"] = summary(latencies)
    REPORT.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def assert_no_instability(ios_lines: list[str], mac_segment: list[str]) -> None:
    ios_failures = [
        line for line in ios_lines
        if any(token in line for token in ("peripheral_disconnected", "door_command_confirmation_failed"))
    ]
    mac_failures = [
        line for line in mac_segment
        if any(token in line for token in ("wireless_disconnect", "door_command_confirmation_failed"))
    ]
    if ios_failures or mac_failures:
        raise RuntimeError(f"Link instability detected: ios={ios_failures} mac={mac_failures}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--count", type=int, default=20)
    parser.add_argument("--timeout", type=float, default=8)
    parser.add_argument("--startup-timeout", type=float, default=15)
    parser.add_argument("--settle", type=float, default=0.15)
    parser.add_argument("--max-confirm-ms", type=int, default=750)
    parser.add_argument(
        "--no-final-relaunch",
        action="store_true",
        help="Leave the iPhone app terminated so another chained physical test can launch it cleanly.",
    )
    args = parser.parse_args()
    if args.count < 4:
        raise SystemExit("--count must be at least 4")

    subprocess.run(["open", "-a", str(Path.home() / "Applications/DoorUnlockerAdmin.app")], check=True)
    device = device_identifier()
    console = IOSConsole(device)
    mac_start = len(mac_lines())
    results: list[dict[str, int | str]] = []
    failure: str | None = None

    try:
        console.start()
        console.wait_for(lambda line: "door_command_usable" in line, timeout=args.startup_timeout)
        _, initial_state_line = console.wait_for(
            lambda line: (
                "door_state_received locked" in line
                or "door_state_received unlocked" in line
            ),
            timeout=args.startup_timeout,
        )

        next_command = initial_command_from_state(initial_state_line)
        for index in range(args.count):
            origin = "iphone" if index % 2 == 0 else "mac"
            command = next_command
            transition = "unlocking" if command == "UNLOCK" else "locking"
            ios_start = len(console.lines)
            current_mac_start = len(mac_lines())

            if origin == "iphone":
                launch_ms = launch_iphone_command(device, command)
                _, requested_line = console.wait_for(
                    lambda line: f"door_command_requested {command}" in line,
                    start_index=ios_start,
                    timeout=args.timeout,
                )
                _, confirmed_line = console.wait_for(
                    lambda line: f"door_command_confirmed {command} state={transition}" in line,
                    start_index=ios_start,
                    timeout=args.timeout,
                )
                _, _ = wait_for_mac_event(
                    current_mac_start,
                    lambda event: event == f"wireless_state_received {transition}",
                    timeout=args.timeout,
                )
                requested = ios_event(requested_line)
                confirmed = ios_event(confirmed_line)
                assert requested and confirmed
                latency = confirmed[0] - requested[0]
                result = {
                    "origin": origin,
                    "command": command,
                    "requestToConfirmationMs": latency,
                    "devicectlDispatchMs": launch_ms,
                }
            else:
                click_mac_door_command()
                requested_at, requested_event = wait_for_mac_event(
                    current_mac_start,
                    lambda event: event.startswith("door_command_requested "),
                    timeout=args.timeout,
                )
                actual_command = requested_event.rsplit(" ", 1)[-1]
                if actual_command != command:
                    raise RuntimeError(f"Mac requested {actual_command}, expected {command}")
                confirmed_at, _ = wait_for_mac_event(
                    current_mac_start,
                    lambda event: event.startswith(f"door_command_confirmed {command} state={transition}"),
                    timeout=args.timeout,
                )
                console.wait_for(
                    lambda line: f"door_state_received {transition}" in line,
                    start_index=ios_start,
                    timeout=args.timeout,
                )
                result = {
                    "origin": origin,
                    "command": command,
                    "requestToConfirmationMs": confirmed_at - requested_at,
                }

            results.append(result)
            print(
                f"{index + 1:02d} {origin:6s} {command}: "
                f"confirm={result['requestToConfirmationMs']}ms",
                flush=True,
            )
            next_command = "LOCK" if command == "UNLOCK" else "UNLOCK"
            time.sleep(args.settle)
        assert_no_instability(console.lines, mac_lines()[mac_start:])
    except Exception as error:
        failure = f"{type(error).__name__}: {error}"
        raise
    finally:
        diagnostics = console.lines + mac_lines()[mac_start:]
        write_report(
            results=results,
            expected_count=args.count,
            max_confirm_ms=args.max_confirm_ms,
            failure=failure,
            diagnostics=diagnostics,
        )
        console.stop()
        if not args.no_final_relaunch:
            subprocess.run(
                [
                    "/usr/bin/xcrun",
                    "devicectl",
                    "device",
                    "process",
                    "launch",
                    "--device",
                    device,
                    BUNDLE_ID,
                ],
                cwd=ROOT,
                env={**os.environ, "DEVELOPER_DIR": DEVELOPER_DIR},
                check=False,
                capture_output=True,
                text=True,
            )

    latencies = [int(result["requestToConfirmationMs"]) for result in results]
    passed = len(results) == args.count and max(latencies) <= args.max_confirm_ms
    print(json.dumps(summary(latencies), sort_keys=True))
    if not passed:
        raise SystemExit(f"Mixed-client confirmation exceeded {args.max_confirm_ms} ms")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
