#!/usr/bin/env python3
"""Collect physical iPhone cold and warm secure-command readiness gates."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import subprocess
import time

from ios_launch_performance_contract import (
    COLD_MEDIAN_LIMIT_MS,
    COLD_P95_LIMIT_MS,
    MINIMUM_SAMPLES,
    PROOF_PATH,
    WARM_MEDIAN_LIMIT_MS,
    WARM_P95_LIMIT_MS,
    app_version,
    critical_path_sha256,
    firmware_version,
    metrics,
    validate_proof,
)
from stress_mixed_clients import BUNDLE_ID, DEVELOPER_DIR, IOSConsole, ROOT, device_identifier


COLD_EVENT = re.compile(r"DUStartup\s+(\d+)ms\s+door_command_dispatch_ready")
WARM_EVENT = re.compile(r"DUWarmLaunch\s+(\d+)ms\s+door_command_dispatch_ready")
SETTINGS_BUNDLE_ID = "com.apple.Preferences"


def launch(device: str, bundle_id: str) -> None:
    env = os.environ.copy()
    env["DEVELOPER_DIR"] = DEVELOPER_DIR
    subprocess.run(
        ["/usr/bin/xcrun", "devicectl", "device", "process", "launch", "--device", device, bundle_id],
        cwd=ROOT,
        env=env,
        check=True,
        capture_output=True,
        text=True,
    )


def event_ms(line: str, pattern: re.Pattern[str]) -> int:
    match = pattern.search(line)
    if not match:
        raise RuntimeError(f"Invalid launch telemetry: {line}")
    return int(match.group(1))


def write_report(cold: list[int], warm: list[int], failure: str | None) -> list[str]:
    report = {
        "schemaVersion": 1,
        "generatedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
        "passed": failure is None,
        "deviceClass": "physical iPhone",
        "appVersion": app_version(),
        "firmwareVersion": firmware_version(),
        "criticalPathSha256": critical_path_sha256(),
        "limitsMs": {
            "coldMedian": COLD_MEDIAN_LIMIT_MS,
            "coldP95": COLD_P95_LIMIT_MS,
            "warmMedian": WARM_MEDIAN_LIMIT_MS,
            "warmP95": WARM_P95_LIMIT_MS,
        },
        "cold": {"samplesMs": cold, "metrics": metrics(cold) if cold else None},
        "warm": {"samplesMs": warm, "metrics": metrics(warm) if warm else None},
        "failure": failure,
    }
    PROOF_PATH.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return validate_proof(report)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--samples", type=int, default=MINIMUM_SAMPLES)
    parser.add_argument("--timeout", type=float, default=10)
    parser.add_argument("--cold-settle", type=float, default=1.5)
    parser.add_argument("--background-settle", type=float, default=0.6)
    args = parser.parse_args()
    if args.samples < MINIMUM_SAMPLES:
        raise SystemExit(f"--samples must be at least {MINIMUM_SAMPLES}")

    device = device_identifier()
    cold: list[int] = []
    warm: list[int] = []
    console: IOSConsole | None = None
    failure: str | None = None
    try:
        for index in range(args.samples):
            if console is not None:
                console.stop()
                time.sleep(args.cold_settle)
            console = IOSConsole(device)
            console.start()
            _, line = console.wait_for(lambda value: COLD_EVENT.search(value) is not None, timeout=args.timeout)
            value = event_ms(line, COLD_EVENT)
            cold.append(value)
            print(f"cold {index + 1:02d}: {value}ms")

        time.sleep(2.1)
        for index in range(args.samples):
            start = len(console.lines)
            launch(device, SETTINGS_BUNDLE_ID)
            time.sleep(args.background_settle)
            launch(device, BUNDLE_ID)
            _, line = console.wait_for(
                lambda value: WARM_EVENT.search(value) is not None,
                start_index=start,
                timeout=args.timeout,
            )
            value = event_ms(line, WARM_EVENT)
            warm.append(value)
            print(f"warm {index + 1:02d}: {value}ms")
    except Exception as error:
        failure = str(error)
        print(f"launch benchmark failed: {failure}")
    finally:
        if console is not None:
            console.stop()
        launch(device, BUNDLE_ID)

    failures = write_report(cold, warm, failure)
    if failures:
        for item in failures:
            print(f"FAIL: {item}")
        return 1
    print(f"cold: {metrics(cold)}")
    print(f"warm: {metrics(warm)}")
    print(f"proof: {PROOF_PATH.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
