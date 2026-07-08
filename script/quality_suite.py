#!/usr/bin/env python3
"""Door Unlocker quality suite.

This is the top-level gate for release-quality changes. It combines architecture
scores, size/line budgets, independently compiled package tests, and app builds.
Live hardware/UI checks are intentionally opt-in because they can send real
lock/unlock commands.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from dataclasses import asdict, dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_DEVELOPER_DIR = "/Applications/Xcode.app/Contents/Developer"


@dataclass
class SuiteStep:
    name: str
    command: list[str]
    status: str
    durationSeconds: float
    exitCode: int
    summary: str


def run_command(name: str, command: list[str], env: dict[str, str]) -> SuiteStep:
    started_at = time.monotonic()
    print(f"\n==> {name}")
    print("$ " + " ".join(command))
    process = subprocess.run(
        command,
        cwd=ROOT,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    duration = time.monotonic() - started_at
    output = process.stdout.rstrip()
    if output:
        print(output)

    status = "pass" if process.returncode == 0 else "fail"
    summary = summarize_output(output)
    print(f"<== {name}: {status} ({duration:.1f}s)")
    return SuiteStep(
        name=name,
        command=command,
        status=status,
        durationSeconds=round(duration, 2),
        exitCode=process.returncode,
        summary=summary,
    )


def summarize_output(output: str) -> str:
    if not output:
        return ""

    interesting_prefixes = (
        "Maintainability:",
        "iOS:",
        "Mac:",
        "Test Suite 'All tests' passed",
        "Test Suite 'All tests' failed",
        "** BUILD SUCCEEDED **",
        "** BUILD FAILED **",
        "Mac app installed and codesign verified",
        "iPhone app installed.",
    )
    lines = [line for line in output.splitlines() if line.startswith(interesting_prefixes)]
    if lines:
        return " | ".join(lines[-6:])

    return output.splitlines()[-1][:240]


def base_steps(args: argparse.Namespace) -> list[tuple[str, list[str]]]:
    steps: list[tuple[str, list[str]]] = [
        (
            "Maintainability size/length gate",
            ["python3", "script/score_maintainability.py", "--threshold", str(args.maintainability_threshold)],
        ),
        (
            "Low coupling / high modularity / independence gate",
            [
                "python3",
                "script/score_modularity.py",
                "--threshold",
                str(args.modularity_threshold),
                "--write-graph",
                "docs/dependency-graph.md",
            ],
        ),
        (
            "iOS/Mac shared parity gate",
            ["python3", "script/score_shared_parity.py", "--threshold", str(args.shared_parity_threshold)],
        ),
        (
            "Shared package independent tests",
            ["swift", "test", "--package-path", "shared/DoorUnlockerShared"],
        ),
        (
            "Mac core/admin independent tests",
            ["swift", "test", "--package-path", "mac/DoorUnlockerAdmin"],
        ),
    ]

    if not args.fast:
        steps.extend(
            [
                (
                    "iOS app generic build",
                    [
                        "xcodebuild",
                        "-project",
                        "ios/DoorUnlockerApp/DoorUnlocker.xcodeproj",
                        "-scheme",
                        "DoorUnlocker",
                        "-configuration",
                        "Debug",
                        "-destination",
                        "generic/platform=iOS",
                        "CODE_SIGNING_ALLOWED=NO",
                        "build",
                    ],
                ),
                (
                    "Mac app build",
                    ["./script/build_and_run.sh", "--verify"],
                ),
            ]
        )

    if args.live_mac_ui:
        steps.append(("Live Mac control surface smoke test", ["./script/check_mac_control_surface.sh"]))

    if args.install_mac:
        steps.append(("Install Mac app", ["./script/build_and_run.sh", "--install"]))

    if args.install_ios:
        install_command = ["./script/install_ios_app.sh"]
        if args.no_launch_ios:
            install_command.append("--no-launch")
        steps.append(("Install iPhone app", install_command))

    return steps


def write_report(path: Path, steps: list[SuiteStep], total_seconds: float) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "passed": all(step.status == "pass" for step in steps),
        "durationSeconds": round(total_seconds, 2),
        "steps": [asdict(step) for step in steps],
    }
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description="Run Door Unlocker quality gates.")
    parser.add_argument("--fast", action="store_true", help="Skip app builds; run score gates and package tests only.")
    parser.add_argument("--live-mac-ui", action="store_true", help="Click the Mac lock/unlock control surface. Sends a real command.")
    parser.add_argument("--install-mac", action="store_true", help="Build and install the Mac app after gates.")
    parser.add_argument("--install-ios", action="store_true", help="Build and install the iPhone app after gates.")
    parser.add_argument("--no-launch-ios", action="store_true", help="When installing iOS, do not launch the app.")
    parser.add_argument("--modularity-threshold", type=float, default=95.0)
    parser.add_argument("--maintainability-threshold", type=float, default=90.0)
    parser.add_argument("--shared-parity-threshold", type=float, default=95.0)
    parser.add_argument(
        "--report",
        type=Path,
        default=ROOT / "docs" / "quality-suite-last-run.json",
        help="Write a machine-readable suite report.",
    )
    args = parser.parse_args()

    env = os.environ.copy()
    env.setdefault("DEVELOPER_DIR", DEFAULT_DEVELOPER_DIR)
    started_at = time.monotonic()
    steps: list[SuiteStep] = []

    for name, command in base_steps(args):
        step = run_command(name, command, env)
        steps.append(step)
        if step.status != "pass":
            break

    total_seconds = time.monotonic() - started_at
    write_report(args.report, steps, total_seconds)
    passed = all(step.status == "pass" for step in steps)

    print("\nQuality suite: " + ("PASS" if passed else "FAIL"))
    print(f"Report: {args.report.relative_to(ROOT)}")
    for step in steps:
        print(f"- {step.status.upper()}: {step.name} ({step.durationSeconds:.1f}s)")

    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
