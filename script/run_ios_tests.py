#!/usr/bin/env python3
"""Run iOS adapter tests with coverage and preserve machine-readable evidence."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
RESULT_BUNDLE = ROOT / "build" / "quality" / "ios-tests.xcresult"
COVERAGE_REPORT = ROOT / "docs" / "ios-test-coverage-last-run.json"
DEFAULT_DEVELOPER_DIR = "/Applications/Xcode.app/Contents/Developer"


def run(command: list[str], env: dict[str, str], capture: bool = False) -> subprocess.CompletedProcess[str]:
    print("$ " + " ".join(command))
    return subprocess.run(
        command,
        cwd=ROOT,
        env=env,
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.STDOUT if capture else None,
    )


def coverage_summary(payload: dict[str, object]) -> dict[str, object]:
    targets = payload.get("targets", [])
    summaries = []
    if isinstance(targets, list):
        for target in targets:
            if not isinstance(target, dict):
                continue
            summaries.append({
                "name": target.get("name"),
                "lineCoverage": target.get("lineCoverage"),
                "executableLines": target.get("executableLines"),
                "coveredLines": target.get("coveredLines"),
            })
    return {
        "schemaVersion": 1,
        "source": str(RESULT_BUNDLE.relative_to(ROOT)),
        "targets": summaries,
        "note": "Coverage is diagnostic evidence, not a release threshold. Add tests around uncovered critical behavior instead of optimizing a single percentage.",
    }


def simulator_destination(env: dict[str, str]) -> str:
    configured = env.get("IOS_TEST_DESTINATION")
    if configured:
        return configured

    result = run(["xcrun", "simctl", "list", "devices", "available", "--json"], env, capture=True)
    if result.returncode:
        raise RuntimeError(result.stdout or "Could not list iOS simulators")

    payload = json.loads(result.stdout)
    candidates: list[tuple[tuple[int, ...], int, dict[str, object]]] = []
    preferred_names = ("iPhone 17 Pro", "iPhone 16 Pro", "iPhone Air")
    for runtime, devices in payload.get("devices", {}).items():
        if "iOS" not in runtime or not isinstance(devices, list):
            continue
        version = tuple(int(part) for part in runtime.rsplit("iOS-", 1)[-1].split("-") if part.isdigit())
        for device in devices:
            if not isinstance(device, dict) or device.get("isAvailable") is False:
                continue
            name = str(device.get("name", ""))
            if not name.startswith("iPhone"):
                continue
            preference = len(preferred_names) - preferred_names.index(name) if name in preferred_names else 0
            candidates.append((version, preference, device))

    if not candidates:
        raise RuntimeError("No available iPhone simulator was found")

    _, _, selected = max(candidates, key=lambda candidate: (candidate[0], candidate[1]))
    print(f"Selected simulator: {selected['name']} ({selected['udid']})")
    return f"platform=iOS Simulator,id={selected['udid']}"


def main() -> int:
    env = os.environ.copy()
    env.setdefault("DEVELOPER_DIR", DEFAULT_DEVELOPER_DIR)
    try:
        destination = simulator_destination(env)
    except (RuntimeError, ValueError, KeyError, json.JSONDecodeError) as error:
        print(f"iOS adapter tests: FAIL ({error})")
        return 2

    shutil.rmtree(RESULT_BUNDLE, ignore_errors=True)
    RESULT_BUNDLE.parent.mkdir(parents=True, exist_ok=True)
    test = run([
        "xcodebuild",
        "-project", "ios/DoorUnlockerApp/DoorUnlocker.xcodeproj",
        "-scheme", "DoorUnlocker",
        "-configuration", "Debug",
        "-destination", destination,
        "-only-testing:DoorUnlockerTests",
        "-enableCodeCoverage", "YES",
        "-resultBundlePath", str(RESULT_BUNDLE),
        "-quiet",
        "test",
    ], env, capture=True)
    if test.returncode:
        print(test.stdout or "xcodebuild failed without output")
        print("iOS adapter tests: FAIL")
        return test.returncode

    for line in (test.stdout or "").splitlines():
        if "Test case '" in line or line.strip() in ("** TEST SUCCEEDED **", "** TEST FAILED **"):
            print(line)

    coverage = run([
        "xcrun", "xccov", "view", "--report", "--json", str(RESULT_BUNDLE)
    ], env, capture=True)
    if coverage.returncode:
        print(coverage.stdout or "xccov failed without output")
        print("iOS adapter tests passed, but coverage extraction failed.")
        return coverage.returncode

    payload = json.loads(coverage.stdout)
    COVERAGE_REPORT.write_text(
        json.dumps(coverage_summary(payload), indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    print("iOS adapter tests: PASS")
    print(f"Coverage report: {COVERAGE_REPORT.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
