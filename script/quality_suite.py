#!/usr/bin/env python3
"""Door Unlocker quality suite.

This is the top-level gate for release-quality changes. It combines calibrated
tooling checks, architecture heuristics, executable unit/integration tests,
firmware compilation, model validation, coverage evidence, and app builds.
Live hardware/UI checks are intentionally opt-in because they can send real
lock/unlock commands.
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
import platform
import subprocess
import sys
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_DEVELOPER_DIR = "/Applications/Xcode.app/Contents/Developer"
XCODE_SWIFT = (
    "/Applications/Xcode.app/Contents/Developer/Toolchains/"
    "XcodeDefault.xctoolchain/usr/bin/swift"
)
MIXED_CLIENT_COMMAND_REPORT = ROOT / "docs/mixed-client-stress-last-run.json"
MIXED_CLIENT_SETTINGS_REPORT = ROOT / "docs/mixed-client-settings-last-run.json"
CLIENT_RELAUNCH_REPORT = ROOT / "docs/client-relaunch-stress-last-run.json"


@dataclass
class SuiteStep:
    name: str
    command: list[str]
    status: str
    durationSeconds: float
    exitCode: int
    summary: str
    warningCount: int = 0
    warnings: list[str] = field(default_factory=list)


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
    warnings = list(dict.fromkeys(
        line.strip()
        for line in output.splitlines()
        if "warning:" in line.lower()
    ))
    print(f"<== {name}: {status} ({duration:.1f}s)")
    return SuiteStep(
        name=name,
        command=command,
        status=status,
        durationSeconds=round(duration, 2),
        exitCode=process.returncode,
        summary=summary,
        warningCount=len(warnings),
        warnings=warnings[:10],
    )


def summarize_output(output: str) -> str:
    if not output:
        return ""

    interesting_prefixes = (
        "Maintainability:",
        "iOS:",
        "Mac:",
        "Shared parity evidence registration:",
        "Fast command contract:",
        "iOS launch performance proof:",
        "iOS adapter tests:",
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


def public_report_text(value: str) -> str:
    return value.replace(str(ROOT), ".").replace(str(Path.home()), "~")


def public_step_payload(step: SuiteStep) -> dict[str, object]:
    payload = asdict(step)
    payload["command"] = [public_report_text(value) for value in step.command]
    payload["summary"] = public_report_text(step.summary)
    payload["warnings"] = [public_report_text(value) for value in step.warnings]
    return payload


def tool_version(command: list[str], env: dict[str, str]) -> str | None:
    try:
        result = subprocess.run(
            command,
            cwd=ROOT,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=15,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    output = result.stdout.strip()
    return " | ".join(output.splitlines()[:2]) if result.returncode == 0 and output else None


def base_steps(args: argparse.Namespace) -> list[tuple[str, list[str]]]:
    steps: list[tuple[str, list[str]]] = [
        (
            "Quality tooling negative-control tests",
            ["python3", "-m", "unittest", "discover", "-s", "script/tests", "-p", "test_*.py"],
        ),
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
            "iOS/Mac shared ownership and test-registration gate",
            ["python3", "script/score_shared_parity.py", "--threshold", str(args.shared_parity_threshold)],
        ),
    ]

    if not args.fast:
        steps.append(("Controller firmware compile and package verification", ["./script/flash_xiao_uf2.sh", "--build-only"]))
        steps.append(("Signed dual-bank bootloader reproducible build", ["./script/build_secure_bootloader.sh"]))

    steps.extend([
        (
            "Signed OTA package and bootloader candidate contract",
            [
                "python3",
                "script/check_ota_bootloader_contract.py",
                *([] if args.fast else ["--require-candidate"]),
            ],
        ),
        (
            "Fast lock/unlock structural contract gate",
            ["python3", "script/check_fast_command_contract.py"],
        ),
        (
            "Controller persistence transaction contract gate",
            ["python3", "script/check_firmware_persistence_contract.py"],
        ),
        (
            "Per-subscriber state delivery contract gate",
            ["python3", "script/check_state_notification_delivery_contract.py"],
        ),
        (
            "Mac single-window scene contract gate",
            ["python3", "script/check_mac_window_scene_contract.py"],
        ),
        (
            "Physical iPhone cold/warm launch performance proof",
            ["python3", "script/check_ios_launch_performance_proof.py"],
        ),
        (
            "Shared package independent tests",
            [XCODE_SWIFT, "test", "--package-path", "shared/DoorUnlockerShared"],
        ),
        (
            "Patched NordicDFU transport independent tests",
            [XCODE_SWIFT, "test", "--package-path", "vendor/IOS-DFU-Library"],
        ),
        (
            "Mac core/admin independent tests",
            [XCODE_SWIFT, "test", "--package-path", "mac/DoorUnlockerAdmin"],
        ),
    ])

    if getattr(args, "firmware_release", False):
        steps.extend([
            (
                "Installed signed dual-bank bootloader and rollback proof",
                ["python3", "script/check_ota_bootloader_contract.py", "--require-production"],
            ),
            (
                "Current package physical BLE OTA release proof",
                ["python3", "script/check_firmware_release_proof.py"],
            ),
        ])

    if not args.fast:
        steps.extend(
            [
                (
                    "iOS adapter tests",
                    ["python3", "script/run_ios_tests.py"],
                ),
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
                        "-quiet",
                        "build",
                    ],
                ),
                (
                    "Mac app build",
                    ["./script/build_and_run.sh", "--verify"],
                ),
                (
                    "Bench wiring path model",
                    ["python3", "script/check_bench_wiring_paths.py"],
                ),
                (
                    "Controller breadboard alignment model",
                    ["python3", "script/check_controller_breadboard_alignment.py"],
                ),
                (
                    "Inline splitter alignment model",
                    ["python3", "script/check_splitter_card_alignment.py"],
                ),
                (
                    "Phase 2 dimensional model",
                    ["python3", "script/check_phase2_html_model.py"],
                ),
            ]
        )

    if args.live_mac_ui:
        steps.append(("Live Mac control surface smoke test", ["./script/check_mac_control_surface.sh"]))

    if args.live_mixed_client:
        steps.extend(
            [
                (
                    "Live client relaunch stress",
                    ["python3", "script/stress_client_relaunch.py", "--cycles", "10"],
                ),
                (
                    "Live mixed-client command stress",
                    ["python3", "script/stress_mixed_clients.py", "--no-final-relaunch"],
                ),
                (
                    "Live mixed-client settings stress",
                    ["python3", "script/stress_mixed_settings.py"],
                ),
            ]
        )

    if args.install_mac:
        steps.append(("Install Mac app", ["./script/build_and_run.sh", "--install"]))

    if args.install_ios:
        install_command = ["./script/install_ios_app.sh"]
        if args.no_launch_ios:
            install_command.append("--no-launch")
        steps.append(("Install iPhone app", install_command))

    return steps


def step_passed(steps: list[SuiteStep], name: str) -> bool:
    return any(step.name == name and step.status == "pass" for step in steps)


def validate_live_mixed_client_report(
    path: Path,
    *,
    collection_key: str,
    count_key: str,
    minimum_count: int,
    not_before: datetime.datetime,
) -> list[str]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        return [f"{path.name}: unreadable evidence ({error})"]

    failures: list[str] = []
    if payload.get("passed") is not True:
        failures.append(f"{path.name}: report did not pass")
    try:
        generated_at = datetime.datetime.fromisoformat(str(payload["generatedAt"]))
        if generated_at.tzinfo is None or generated_at < not_before:
            failures.append(f"{path.name}: evidence is not from this suite run")
    except (KeyError, TypeError, ValueError):
        failures.append(f"{path.name}: invalid generatedAt")

    operations = payload.get(collection_key)
    declared_count = payload.get(count_key)
    if not isinstance(operations, list) or len(operations) < minimum_count:
        failures.append(f"{path.name}: requires at least {minimum_count} {collection_key}")
        operations = []
    if isinstance(operations, list) and declared_count != len(operations):
        failures.append(f"{path.name}: {count_key} does not match {collection_key}")

    origins = {item.get("origin") for item in operations if isinstance(item, dict)}
    if origins != {"iphone", "mac"}:
        failures.append(f"{path.name}: both iPhone and Mac origins are required")
    if any(
        not isinstance(item, dict)
        or not isinstance(item.get("requestToConfirmationMs"), (int, float))
        or item["requestToConfirmationMs"] < 0
        for item in operations
    ):
        failures.append(f"{path.name}: every operation requires a valid confirmation latency")
    if payload.get("simultaneousSubscribersVerified") is not True:
        failures.append(f"{path.name}: cross-subscriber delivery was not verified")
    if payload.get("crossSubscriberConfirmationCount") != len(operations):
        failures.append(f"{path.name}: cross-subscriber count does not match operations")
    return failures


def live_mixed_client_evidence_failures(not_before: datetime.datetime) -> list[str]:
    failures = validate_client_relaunch_report(not_before)
    return failures + validate_live_mixed_client_report(
        MIXED_CLIENT_COMMAND_REPORT,
        collection_key="commands",
        count_key="commandCount",
        minimum_count=4,
        not_before=not_before,
    ) + validate_live_mixed_client_report(
        MIXED_CLIENT_SETTINGS_REPORT,
        collection_key="operations",
        count_key="operationCount",
        minimum_count=2,
        not_before=not_before,
    )


def validate_client_relaunch_report(not_before: datetime.datetime) -> list[str]:
    try:
        payload = json.loads(CLIENT_RELAUNCH_REPORT.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        return [f"{CLIENT_RELAUNCH_REPORT.name}: unreadable evidence ({error})"]

    failures: list[str] = []
    if payload.get("passed") is not True:
        failures.append(f"{CLIENT_RELAUNCH_REPORT.name}: report did not pass")
    try:
        generated_at = datetime.datetime.fromisoformat(str(payload["generatedAt"]))
        if generated_at.tzinfo is None or generated_at < not_before:
            failures.append(f"{CLIENT_RELAUNCH_REPORT.name}: evidence is not from this suite run")
    except (KeyError, TypeError, ValueError):
        failures.append(f"{CLIENT_RELAUNCH_REPORT.name}: invalid generatedAt")

    cycles = payload.get("cycles")
    expected = payload.get("expectedCycleCount")
    if not isinstance(cycles, list) or len(cycles) < 10:
        failures.append(f"{CLIENT_RELAUNCH_REPORT.name}: requires at least 10 cycles")
        cycles = []
    if payload.get("cycleCount") != len(cycles) or expected != len(cycles):
        failures.append(f"{CLIENT_RELAUNCH_REPORT.name}: cycle counts do not agree")
    origins = {item.get("origin") for item in cycles if isinstance(item, dict)}
    if origins != {"iphone", "mac"}:
        failures.append(f"{CLIENT_RELAUNCH_REPORT.name}: both iPhone and Mac origins are required")
    return failures


def write_report(
    path: Path,
    steps: list[SuiteStep],
    total_seconds: float,
    args: argparse.Namespace,
    suite_started_at: datetime.datetime | None = None,
) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    suite_started_at = suite_started_at or datetime.datetime.now(datetime.timezone.utc)
    live_mixed_client_failures = (
        live_mixed_client_evidence_failures(suite_started_at)
        if getattr(args, "live_mixed_client", False)
        else ["Live mixed-client verification was not requested."]
    )
    selected_passed = all(step.status == "pass" for step in steps) and (
        not getattr(args, "live_mixed_client", False) or not live_mixed_client_failures
    )
    platform_adapter_vectors_verified = all(
        step_passed(steps, name)
        for name in (
            "Shared package independent tests",
            "Mac core/admin independent tests",
            "iOS adapter tests",
        )
    )
    build_parity_verified = all(
        step_passed(steps, name)
        for name in ("iOS app generic build", "Mac app build")
    )
    live_mixed_client_verified = (
        not live_mixed_client_failures
        and step_passed(steps, "Live mixed-client command stress")
        and step_passed(steps, "Live mixed-client settings stress")
        and step_passed(steps, "Live client relaunch stress")
    )
    project_warning_prefixes = (str(ROOT), "ios/", "mac/", "shared/", "firmware/", "script/")
    project_warnings = [
        warning
        for step in steps
        for warning in step.warnings
        if warning.startswith(project_warning_prefixes) or str(ROOT) in warning
    ]
    env = os.environ.copy()
    env["DEVELOPER_DIR"] = DEFAULT_DEVELOPER_DIR
    payload = {
        "schemaVersion": 2,
        "generatedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "mode": "fast" if args.fast else "full",
        "passed": selected_passed,
        "fullSuitePassed": selected_passed and not args.fast,
        "durationSeconds": round(total_seconds, 2),
        "expectedStepCount": len(base_steps(args)),
        "executedStepCount": len(steps),
        "environment": {
            "python": platform.python_version(),
            "platform": platform.platform(),
            "xcode": tool_version(["xcodebuild", "-version"], env),
            "swift": tool_version([XCODE_SWIFT, "--version"], env),
            "arduinoCLI": tool_version(["arduino-cli", "version"], env),
        },
        "claims": {
            "qualityToolingSelfTested": step_passed(steps, "Quality tooling negative-control tests"),
            "sharedContractBehaviorVerified": step_passed(steps, "Shared package independent tests"),
            "platformAdapterVectorsVerified": platform_adapter_vectors_verified,
            "platformBuildParityVerified": build_parity_verified,
            "firmwareCompiles": step_passed(steps, "Controller firmware compile and package verification"),
            "bootloaderCandidateReproduces": step_passed(
                steps,
                "Signed dual-bank bootloader reproducible build",
            ),
            "physicalIOSLaunchPerformanceVerified": step_passed(
                steps,
                "Physical iPhone cold/warm launch performance proof",
            ),
            "liveBluetoothHardwareVerified": (
                step_passed(steps, "Live Mac control surface smoke test")
                or live_mixed_client_verified
            ),
            "endToEndCrossPlatformBluetoothParityVerified": (
                platform_adapter_vectors_verified
                and build_parity_verified
                and live_mixed_client_verified
            ),
            "warningFree": all(step.warningCount == 0 for step in steps),
            "projectWarningFree": not project_warnings,
        },
        "limitations": [
            "Architecture and maintainability scores are transparent project heuristics, not Apple-issued grades.",
            "A fast run does not execute iOS adapter tests, firmware compilation, app builds, or HTML/CAD consistency checks.",
            "Bluetooth timing and physical servo movement are only verified when an opt-in live hardware step runs.",
            "Coverage percentages are diagnostic; passing does not imply every branch is exercised.",
        ],
        "liveMixedClientEvidence": {
            "requested": getattr(args, "live_mixed_client", False),
            "verified": live_mixed_client_verified,
            "failures": live_mixed_client_failures,
            "commandReport": str(MIXED_CLIENT_COMMAND_REPORT.relative_to(ROOT)),
            "settingsReport": str(MIXED_CLIENT_SETTINGS_REPORT.relative_to(ROOT)),
            "relaunchReport": str(CLIENT_RELAUNCH_REPORT.relative_to(ROOT)),
        },
        "steps": [public_step_payload(step) for step in steps],
    }
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description="Run Door Unlocker quality gates.")
    parser.add_argument("--fast", action="store_true", help="Skip app builds; run score gates and package tests only.")
    parser.add_argument("--fail-fast", action="store_true", help="Stop after the first failed step instead of collecting all independent failures.")
    parser.add_argument("--live-mac-ui", action="store_true", help="Click the Mac lock/unlock control surface. Sends a real command.")
    parser.add_argument(
        "--live-mixed-client",
        action="store_true",
        help="Run real alternating iPhone/Mac command and settings stress checks.",
    )
    parser.add_argument("--install-mac", action="store_true", help="Build and install the Mac app after gates.")
    parser.add_argument("--install-ios", action="store_true", help="Build and install the iPhone app after gates.")
    parser.add_argument("--no-launch-ios", action="store_true", help="When installing iOS, do not launch the app.")
    parser.add_argument(
        "--firmware-release",
        action="store_true",
        help="Require a matching physical BLE OTA entry/upload/reboot/verification proof.",
    )
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
    if not args.report.is_absolute():
        args.report = ROOT / args.report

    env = os.environ.copy()
    env["DEVELOPER_DIR"] = DEFAULT_DEVELOPER_DIR
    suite_started_at = datetime.datetime.now(datetime.timezone.utc)
    started_at = time.monotonic()
    steps: list[SuiteStep] = []

    for name, command in base_steps(args):
        step = run_command(name, command, env)
        steps.append(step)
        if step.status != "pass" and args.fail_fast:
            break

    total_seconds = time.monotonic() - started_at
    write_report(args.report, steps, total_seconds, args, suite_started_at)
    passed = all(step.status == "pass" for step in steps) and (
        not args.live_mixed_client or not live_mixed_client_evidence_failures(suite_started_at)
    )

    print("\nQuality suite: " + ("PASS" if passed else "FAIL"))
    try:
        report_display = args.report.relative_to(ROOT)
    except ValueError:
        report_display = args.report
    print(f"Report: {report_display}")
    for step in steps:
        print(f"- {step.status.upper()}: {step.name} ({step.durationSeconds:.1f}s)")

    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
