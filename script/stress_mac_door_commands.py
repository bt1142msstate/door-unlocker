#!/usr/bin/env python3
"""Run alternating real Mac BLE door commands and verify every confirmation."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import re
import statistics
import subprocess
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / "dist/door-unlocker"
TRACE = Path.home() / "Library/Application Support/DoorUnlockerAdmin/startup-timing.log"
REPORT = ROOT / "docs/command-stress-last-run.json"
EVENT = re.compile(r"DUMacStartup\s+(\d+)ms\s+(.+)$")


def events_after(start_line: int) -> list[tuple[int, str]]:
    events: list[tuple[int, str]] = []
    for line in TRACE.read_text(encoding="utf-8", errors="replace").splitlines()[start_line:]:
        match = EVENT.search(line)
        if match:
            events.append((int(match.group(1)), match.group(2)))
    return events


def run_command(command: str, timeout: float) -> dict[str, int | str]:
    start_line = len(TRACE.read_text(encoding="utf-8", errors="replace").splitlines())
    subprocess.run([str(CLI), command.lower()], cwd=ROOT, check=True, capture_output=True, text=True)
    deadline = time.monotonic() + timeout
    segment: list[tuple[int, str]] = []
    while time.monotonic() < deadline:
        segment = events_after(start_line)
        requested = confirmed = None
        sent_events: list[int] = []
        for uptime, event in segment:
            if requested is None and event == f"door_command_requested {command}":
                requested = uptime
            elif event == f"wireless_command_sent {command}":
                sent_events.append(uptime)
            elif event.startswith(f"door_command_confirmed {command} "):
                confirmed = uptime
        if requested is not None and sent_events and confirmed is not None:
            break
        time.sleep(0.02)

    failures = [
        event for _, event in segment
        if event.startswith(("wireless_disconnect", "door_command_confirmation_failed"))
    ]
    if failures:
        raise RuntimeError(f"{command} destabilized the link: {failures}")
    if requested is None or not sent_events or confirmed is None:
        raise RuntimeError(f"{command} did not complete its request/write/confirmation contract")
    if len(sent_events) != 1:
        raise RuntimeError(f"{command} wrote {len(sent_events)} times for one request")
    sent = sent_events[0]
    return {
        "command": command,
        "requestToWriteMs": sent - requested,
        "writeToConfirmationMs": confirmed - sent,
        "requestToConfirmationMs": confirmed - requested,
    }


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


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--count", type=int, default=10)
    parser.add_argument("--timeout", type=float, default=5)
    parser.add_argument("--settle", type=float, default=0.12)
    parser.add_argument("--max-confirm-ms", type=int, default=500)
    args = parser.parse_args()
    if args.count < 2:
        raise SystemExit("--count must be at least 2")

    results = []
    for index in range(args.count):
        command = "UNLOCK" if index % 2 == 0 else "LOCK"
        result = run_command(command, args.timeout)
        results.append(result)
        print(
            f"{index + 1:02d} {command}: write={result['requestToWriteMs']}ms "
            f"confirm={result['requestToConfirmationMs']}ms"
        )
        time.sleep(args.settle)

    confirmation_values = [int(result["requestToConfirmationMs"]) for result in results]
    passed = max(confirmation_values) <= args.max_confirm_ms
    report = {
        "generatedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
        "passed": passed,
        "commandCount": len(results),
        "maximumAllowedConfirmationMs": args.max_confirm_ms,
        "requestToWriteMs": summary([int(result["requestToWriteMs"]) for result in results]),
        "writeToConfirmationMs": summary([int(result["writeToConfirmationMs"]) for result in results]),
        "requestToConfirmationMs": summary(confirmation_values),
        "commands": results,
    }
    REPORT.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(report["requestToConfirmationMs"], sort_keys=True))
    if not passed:
        raise SystemExit(f"Confirmation exceeded {args.max_confirm_ms} ms")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
