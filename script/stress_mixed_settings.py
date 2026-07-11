#!/usr/bin/env python3
"""Alternate iPhone and Mac timeout writes and verify durable cross-client convergence."""

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
    MAC_EVENT,
    MAC_TRACE,
    ROOT,
    device_identifier,
    ios_event,
    mac_lines,
    wait_for_mac_event,
)


REPORT = ROOT / "docs/mixed-client-settings-last-run.json"


def launch_iphone_timeout(device: str, seconds: int) -> int:
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
            f"doorunlocker://debug-timeout?seconds={seconds}",
            BUNDLE_ID,
        ],
        cwd=ROOT,
        env=env,
        check=True,
        capture_output=True,
        text=True,
    )
    return round((time.monotonic() - started) * 1000)


def run_mac_timeout(seconds: int) -> None:
    subprocess.run(
        [str(ROOT / "dist/door-unlocker"), "timeout", str(seconds)],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
    )


def summary(values: list[int]) -> dict[str, float | int]:
    ordered = sorted(values)
    return {
        "minimum": min(values),
        "median": round(statistics.median(values), 1),
        "mean": round(statistics.mean(values), 1),
        "maximum": max(values),
        "p95": ordered[min(len(ordered) - 1, max(0, int(len(ordered) * 0.95) - 1))],
    }


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
    report: dict[str, object] = {
        "generatedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
        "passed": (
            failure is None
            and subscribers_verified
            and bool(latencies)
            and max(latencies) <= max_confirm_ms
        ),
        "operationCount": len(results),
        "expectedOperationCount": expected_count,
        "crossSubscriberConfirmationCount": len(results),
        "simultaneousSubscribersVerified": subscribers_verified,
        "maximumAllowedConfirmationMs": max_confirm_ms,
        "operations": results,
        "failures": [failure] if failure else [],
        "diagnostics": diagnostics[-80:],
        "finalTimeoutSeconds": 30,
    }
    if latencies:
        report["requestToConfirmationMs"] = summary(latencies)
    REPORT.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--count", type=int, default=4)
    parser.add_argument("--timeout", type=float, default=8)
    parser.add_argument("--startup-timeout", type=float, default=15)
    parser.add_argument("--max-confirm-ms", type=int, default=5000)
    args = parser.parse_args()
    if args.count < 2 or args.count % 2 != 0:
        raise SystemExit("--count must be an even number of at least 2")

    subprocess.run(["open", "-a", str(Path.home() / "Applications/DoorUnlockerAdmin.app")], check=True)
    device = device_identifier()
    console = IOSConsole(device)
    results: list[dict[str, int | str]] = []
    failure: str | None = None
    mac_session_start = len(mac_lines())

    try:
        console.start()
        console.wait_for(
            lambda line: "door_command_dispatch_ready" in line,
            timeout=args.startup_timeout,
        )
        for index in range(args.count):
            origin = "iphone" if index % 2 == 0 else "mac"
            seconds = 31 if origin == "iphone" else 30
            ios_start = len(console.lines)
            mac_start = len(mac_lines())

            if origin == "iphone":
                dispatch_ms = launch_iphone_timeout(device, seconds)
                _, request_line = console.wait_for(
                    lambda line: f"controller_setting_requested timeout={seconds}" in line,
                    start_index=ios_start,
                    timeout=args.timeout,
                )
                _, confirm_line = console.wait_for(
                    lambda line: f"controller_setting_confirmed autoLockTimeout({seconds})" in line,
                    start_index=ios_start,
                    timeout=args.timeout,
                )
                wait_for_mac_event(
                    mac_start,
                    lambda event: event == f"wireless_state_received timeout_set:{seconds}",
                    timeout=args.timeout,
                )
                requested = ios_event(request_line)
                confirmed = ios_event(confirm_line)
                assert requested and confirmed
                latency = confirmed[0] - requested[0]
                result = {
                    "origin": origin,
                    "seconds": seconds,
                    "requestToConfirmationMs": latency,
                    "devicectlDispatchMs": dispatch_ms,
                }
            else:
                run_mac_timeout(seconds)
                requested_at, _ = wait_for_mac_event(
                    mac_start,
                    lambda event: event == f"controller_setting_requested timeout={seconds}",
                    timeout=args.timeout,
                )
                confirmed_at, _ = wait_for_mac_event(
                    mac_start,
                    lambda event: event == f"controller_setting_confirmed autoLockTimeout({seconds})",
                    timeout=args.timeout,
                )
                console.wait_for(
                    lambda line: f"controller_setting_applied timeout={seconds}" in line,
                    start_index=ios_start,
                    timeout=args.timeout,
                )
                result = {
                    "origin": origin,
                    "seconds": seconds,
                    "requestToConfirmationMs": confirmed_at - requested_at,
                }

            results.append(result)
            print(
                f"{index + 1:02d} {origin:6s} timeout={seconds}s "
                f"confirm={result['requestToConfirmationMs']}ms",
                flush=True,
            )
            time.sleep(0.2)
    except Exception as error:
        failure = f"{type(error).__name__}: {error}"
        raise
    finally:
        diagnostics = console.lines + mac_lines()[mac_session_start:]
        write_report(
            results=results,
            expected_count=args.count,
            max_confirm_ms=args.max_confirm_ms,
            failure=failure,
            diagnostics=diagnostics,
        )
        console.stop()
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
    failures = [
        line for line in console.lines
        if "controller_setting_failed" in line or "secure_command_rejected" in line
    ]
    passed = len(results) == args.count and max(latencies) <= args.max_confirm_ms and not failures
    if failures:
        write_report(
            results=results,
            expected_count=args.count,
            max_confirm_ms=args.max_confirm_ms,
            failure="; ".join(failures),
            diagnostics=console.lines + mac_lines()[mac_session_start:],
        )
    print(json.dumps(summary(latencies), sort_keys=True))
    if not passed:
        raise SystemExit("Mixed-client setting stress failed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
