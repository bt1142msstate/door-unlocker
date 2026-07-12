#!/usr/bin/env python3
"""Summarize structured Door Unlocker OTA timing markers from an app console log."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path


FIRMWARE_EVENT = re.compile(r"DUFirmware\s+(?P<seconds>\d+(?:\.\d+)?)s\s+(?P<event>[a-z_]+)(?:\s+(?P<details>.*))?")
STARTUP_EVENT = re.compile(r"DUStartup\s+(?P<milliseconds>\d+)ms\s+(?P<event>\S+)")
UPLOAD_DURATION = re.compile(r"Upload completed in (?P<seconds>\d+(?:\.\d+)?) seconds")


def summarize(text: str) -> dict[str, object]:
    events: list[dict[str, object]] = []
    startup: dict[str, int] = {}
    upload_seconds: float | None = None

    for line in text.splitlines():
        if match := FIRMWARE_EVENT.search(line):
            events.append(
                {
                    "elapsedSeconds": float(match.group("seconds")),
                    "event": match.group("event"),
                    "details": match.group("details") or None,
                }
            )
        if match := STARTUP_EVENT.search(line):
            startup[match.group("event")] = int(match.group("milliseconds"))
        if match := UPLOAD_DURATION.search(line):
            upload_seconds = float(match.group("seconds"))

    first_by_name = {event["event"]: event for event in events}
    scan_seconds = _elapsed(first_by_name, "bootloader_selected")
    manager_total = _elapsed(first_by_name, "completed")
    entry_ms = startup.get("firmware_send_enter_ota_written")
    verified_ms = startup.get("firmware_pending_cleared")
    end_to_end = None
    if entry_ms is not None and verified_ms is not None:
        end_to_end = round((verified_ms - entry_ms) / 1000, 3)

    verification_seconds = None
    if end_to_end is not None and scan_seconds is not None and upload_seconds is not None:
        verification_seconds = round(max(0, end_to_end - scan_seconds - upload_seconds), 3)

    progress = [event for event in events if event["event"] == "progress"]
    return {
        "endToEndSeconds": end_to_end,
        "bootloaderDiscoverySeconds": scan_seconds,
        "uploadSeconds": upload_seconds,
        "postUploadVerificationSeconds": verification_seconds,
        "managerTotalSeconds": manager_total,
        "progressSamples": progress,
        "events": events,
    }


def _elapsed(events: dict[str, dict[str, object]], name: str) -> float | None:
    event = events.get(name)
    return float(event["elapsedSeconds"]) if event else None


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("log", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()

    report = summarize(args.log.read_text(encoding="utf-8", errors="replace"))
    output = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(output, encoding="utf-8")
    print(output, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
