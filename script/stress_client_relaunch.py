#!/usr/bin/env python3
"""Cycle both apps and prove fresh two-client recovery before every command."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import statistics
import subprocess
import time
from pathlib import Path

from stress_mixed_clients import (
    BUNDLE_ID,
    DEVELOPER_DIR,
    IOSConsole,
    ROOT,
    click_mac_door_command,
    device_identifier,
    initial_command_from_state,
    ios_event,
    launch_iphone_command,
    mac_lines,
    wait_for_mac_event,
)


REPORT = ROOT / "docs/client-relaunch-stress-last-run.json"
MAC_APP = Path.home() / "Applications/DoorUnlockerAdmin.app"


def quit_mac() -> None:
    subprocess.run(
        ["/usr/bin/osascript", "-e", 'tell application "DoorUnlockerAdmin" to quit'],
        check=False,
        capture_output=True,
        text=True,
    )
    deadline = time.monotonic() + 4
    while time.monotonic() < deadline:
        result = subprocess.run(["/usr/bin/pgrep", "-x", "DoorUnlockerAdmin"], capture_output=True)
        if result.returncode != 0:
            return
        time.sleep(0.05)
    subprocess.run(["/usr/bin/pkill", "-x", "DoorUnlockerAdmin"], check=False)


def launch_mac() -> None:
    subprocess.run(["/usr/bin/open", "-a", str(MAC_APP)], check=True)


def percentile(values: list[int], fraction: float) -> int:
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, max(0, int(len(ordered) * fraction) - 1))]


def metrics(values: list[int]) -> dict[str, float | int]:
    return {
        "minimum": min(values),
        "median": round(statistics.median(values), 1),
        "mean": round(statistics.mean(values), 1),
        "p95": percentile(values, 0.95),
        "maximum": max(values),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cycles", type=int, default=10)
    parser.add_argument("--ready-timeout", type=float, default=12)
    parser.add_argument("--command-timeout", type=float, default=6)
    parser.add_argument("--max-ios-ready-ms", type=int, default=4000)
    parser.add_argument("--max-mac-ready-ms", type=int, default=7000)
    parser.add_argument("--max-command-ms", type=int, default=1200)
    args = parser.parse_args()
    if args.cycles < 3:
        raise SystemExit("--cycles must be at least 3")

    device = device_identifier()
    cycles: list[dict[str, int | str]] = []
    diagnostics: list[str] = []
    failure: str | None = None
    console: IOSConsole | None = None

    try:
        for cycle in range(args.cycles):
            if console is not None:
                console.stop()
            quit_mac()
            mac_start = len(mac_lines())
            console = IOSConsole(device)
            console.start()

            _, ios_ready_line = console.wait_for(
                lambda line: "door_command_usable" in line,
                timeout=args.ready_timeout,
            )
            _, state_line = console.wait_for(
                lambda line: "door_state_received locked" in line or "door_state_received unlocked" in line,
                timeout=args.ready_timeout,
            )
            console.wait_for(
                lambda line: "controller_connections_received 1/4" in line,
                timeout=args.ready_timeout,
            )

            launch_mac()
            mac_ready_ms, _ = wait_for_mac_event(
                mac_start,
                lambda event: event == "door_command_usable nonce_ready",
                timeout=args.ready_timeout,
            )
            wait_for_mac_event(
                mac_start,
                lambda event: event.startswith("controller_connections_received 2/4"),
                timeout=args.ready_timeout,
            )
            console.wait_for(
                lambda line: "controller_connections_received 2/4" in line,
                timeout=args.ready_timeout,
            )

            ready_event = ios_event(ios_ready_line)
            if ready_event is None:
                raise RuntimeError("Missing iPhone readiness timing")
            ios_ready_ms = ready_event[0]
            command = initial_command_from_state(state_line)
            transition = "unlocking" if command == "UNLOCK" else "locking"
            ios_start = len(console.lines)
            command_mac_start = len(mac_lines())

            if cycle % 2 == 0:
                launch_iphone_command(device, command)
                _, requested_line = console.wait_for(
                    lambda line: f"door_command_requested {command}" in line,
                    start_index=ios_start,
                    timeout=args.command_timeout,
                )
                _, confirmed_line = console.wait_for(
                    lambda line: f"door_command_confirmed {command} state={transition}" in line,
                    start_index=ios_start,
                    timeout=args.command_timeout,
                )
                wait_for_mac_event(
                    command_mac_start,
                    lambda event: event == f"wireless_state_received {transition}",
                    timeout=args.command_timeout,
                )
                requested = ios_event(requested_line)
                confirmed = ios_event(confirmed_line)
                assert requested and confirmed
                command_ms = confirmed[0] - requested[0]
                origin = "iphone"
            else:
                click_mac_door_command()
                requested_ms, requested_event = wait_for_mac_event(
                    command_mac_start,
                    lambda event: event.startswith("door_command_requested "),
                    timeout=args.command_timeout,
                )
                actual_command = requested_event.rsplit(" ", 1)[-1]
                confirmed_ms, _ = wait_for_mac_event(
                    command_mac_start,
                    lambda event: event.startswith(f"door_command_confirmed {actual_command} state="),
                    timeout=args.command_timeout,
                )
                console.wait_for(
                    lambda line: f"door_state_received {transition}" in line,
                    start_index=ios_start,
                    timeout=args.command_timeout,
                )
                command_ms = confirmed_ms - requested_ms
                origin = "mac"

            ios_segment = console.lines
            mac_segment = mac_lines()[mac_start:]
            unstable_tokens = (
                "door_command_confirmation_failed",
                "secure_command_rejected",
                "storage_fault",
            )
            if any(token in line for token in unstable_tokens for line in ios_segment + mac_segment):
                raise RuntimeError(f"Unstable telemetry in recovery cycle {cycle + 1}")

            result = {
                "cycle": cycle + 1,
                "origin": origin,
                "command": command,
                "iosReadyMs": ios_ready_ms,
                "macReadyMs": mac_ready_ms,
                "commandConfirmationMs": command_ms,
            }
            cycles.append(result)
            diagnostics.extend((ios_segment + mac_segment)[-30:])
            print(
                f"{cycle + 1:02d} ios-ready={ios_ready_ms}ms mac-ready={mac_ready_ms}ms "
                f"{origin} {command}={command_ms}ms",
                flush=True,
            )

        ios_ready = [int(item["iosReadyMs"]) for item in cycles]
        mac_ready = [int(item["macReadyMs"]) for item in cycles]
        commands = [int(item["commandConfirmationMs"]) for item in cycles]
        passed = (
            len(cycles) == args.cycles
            and max(ios_ready) <= args.max_ios_ready_ms
            and max(mac_ready) <= args.max_mac_ready_ms
            and max(commands) <= args.max_command_ms
        )
    except Exception as error:
        failure = f"{type(error).__name__}: {error}"
        passed = False
        raise
    finally:
        if console is not None:
            diagnostics.extend(console.lines[-30:])
            console.stop()
        launch_mac()
        subprocess.run(
            [
                "/usr/bin/xcrun", "devicectl", "device", "process", "launch",
                "--device", device, BUNDLE_ID,
            ],
            cwd=ROOT,
            env={**os.environ, "DEVELOPER_DIR": DEVELOPER_DIR},
            check=False,
            capture_output=True,
            text=True,
        )
        report: dict[str, object] = {
            "generatedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
            "passed": passed,
            "cycleCount": len(cycles),
            "expectedCycleCount": args.cycles,
            "cycles": cycles,
            "limitsMs": {
                "iosReady": args.max_ios_ready_ms,
                "macReady": args.max_mac_ready_ms,
                "commandConfirmation": args.max_command_ms,
            },
            "failure": failure,
            "diagnostics": diagnostics[-120:],
        }
        if cycles:
            report["iosReadyMs"] = metrics([int(item["iosReadyMs"]) for item in cycles])
            report["macReadyMs"] = metrics([int(item["macReadyMs"]) for item in cycles])
            report["commandConfirmationMs"] = metrics(
                [int(item["commandConfirmationMs"]) for item in cycles]
            )
        REPORT.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    if not passed:
        raise SystemExit("Client relaunch stress failed")
    print(json.dumps({"iosReadyMs": metrics(ios_ready), "macReadyMs": metrics(mac_ready), "commandMs": metrics(commands)}, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
