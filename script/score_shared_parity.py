#!/usr/bin/env python3
"""Score iOS/macOS shared behavior parity.

This gate checks the contracts that should stay shared between the iPhone and
Mac apps. It intentionally scores cross-platform ownership, not visual sameness:
platform-specific SwiftUI can differ, but protocol, parsing, safety limits, and
control-surface presentation rules should be shared and independently tested.
"""

from __future__ import annotations

import argparse
import json
import re
from dataclasses import dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


@dataclass(frozen=True)
class SourceUse:
    path: Path
    required_needles: tuple[str, ...]


@dataclass(frozen=True)
class Contract:
    name: str
    weight: float
    shared_files: tuple[Path, ...]
    test_files: tuple[Path, ...]
    minimum_test_count: int
    ios_uses: tuple[SourceUse, ...]
    mac_uses: tuple[SourceUse, ...]
    drift_checks: tuple[tuple[str, Path, str, bool], ...] = ()


def rel(path: Path) -> str:
    return str(path.relative_to(ROOT))


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8") if path.exists() else ""


def source_contains(path: Path, needle: str) -> bool:
    return needle in read(path)


def count_tests(paths: tuple[Path, ...]) -> int:
    return sum(read(path).count("func test") for path in paths)


def required_source_use_passes(use: SourceUse) -> bool:
    text = read(use.path)
    return use.path.exists() and all(needle in text for needle in use.required_needles)


def regex_check(path: Path, pattern: str, expected: bool) -> bool:
    return (re.search(pattern, read(path), re.M) is not None) == expected


def contract_score(contract: Contract) -> tuple[float, list[dict[str, object]]]:
    checks: list[tuple[str, bool, str]] = []
    checks.append((
        "shared source exists",
        all(path.exists() for path in contract.shared_files),
        ", ".join(rel(path) for path in contract.shared_files),
    ))
    checks.append((
        "shared tests cover contract",
        count_tests(contract.test_files) >= contract.minimum_test_count,
        f"tests={count_tests(contract.test_files)}, minimum={contract.minimum_test_count}",
    ))
    checks.append((
        "iOS uses shared contract",
        all(required_source_use_passes(use) for use in contract.ios_uses),
        ", ".join(rel(use.path) for use in contract.ios_uses),
    ))
    checks.append((
        "Mac uses shared contract",
        all(required_source_use_passes(use) for use in contract.mac_uses),
        ", ".join(rel(use.path) for use in contract.mac_uses),
    ))

    for label, path, pattern, expected in contract.drift_checks:
        checks.append((label, regex_check(path, pattern, expected), rel(path)))

    details = [
        {
            "name": name,
            "passed": passed,
            "detail": detail,
        }
        for name, passed, detail in checks
    ]
    passed = sum(1 for _, value, _ in checks if value)
    return 100 * passed / len(checks), details


SHARED = ROOT / "shared" / "DoorUnlockerShared"
SHARED_SOURCES = SHARED / "Sources" / "DoorUnlockerShared"
SHARED_TESTS = SHARED / "Tests" / "DoorUnlockerSharedTests"
IOS_APP = ROOT / "ios" / "DoorUnlockerApp"
IOS_DOOR = IOS_APP / "DoorUnlocker"
MAC_PACKAGE = ROOT / "mac" / "DoorUnlockerAdmin"
MAC_ADMIN = MAC_PACKAGE / "Sources" / "DoorUnlockerAdmin"
MAC_CORE = MAC_PACKAGE / "Sources" / "DoorUnlockerCore"


CONTRACTS = (
    Contract(
        name="secure-command-codec",
        weight=0.24,
        shared_files=(SHARED_SOURCES / "DoorSecureCommandCodec.swift",),
        test_files=(SHARED_TESTS / "DoorSecureCommandCodecTests.swift",),
        minimum_test_count=5,
        ios_uses=(
            SourceUse(IOS_DOOR / "DoorCommandAuthenticator.swift", ("DoorSecureCommandCodec",)),
        ),
        mac_uses=(
            SourceUse(MAC_CORE / "DoorCommandAuthenticator.swift", ("DoorSecureCommandCodec",)),
        ),
        drift_checks=(
            (
                "iOS does not own opcode table",
                IOS_DOOR / "DoorCommandAuthenticator.swift",
                r"fastCommand[A-Za-z0-9]+Op\s*=",
                False,
            ),
            (
                "Mac does not own opcode table",
                MAC_CORE / "DoorCommandAuthenticator.swift",
                r"fastCommand[A-Za-z0-9]+Op\s*=",
                False,
            ),
        ),
    ),
    Contract(
        name="controller-safety-policy",
        weight=0.20,
        shared_files=(SHARED_SOURCES / "DoorControllerPolicy.swift",),
        test_files=(SHARED_TESTS / "DoorControllerPolicyTests.swift",),
        minimum_test_count=4,
        ios_uses=(
            SourceUse(
                IOS_DOOR / "DoorUnlockerController.swift",
                (
                    "DoorControllerPolicy.defaultAutoLockSeconds",
                    "DoorControllerPolicy.clampedServoAngles",
                    "DoorControllerPolicy.clampedProximityUnlockRSSIThreshold",
                ),
            ),
        ),
        mac_uses=(
            SourceUse(
                MAC_CORE / "ControllerModels.swift",
                (
                    "DoorControllerPolicy.defaultAutoLockSeconds",
                    "DoorControllerPolicy.clampedServoAngles",
                    "DoorControllerPolicy.servoAnglesAreValid",
                ),
            ),
            SourceUse(
                MAC_ADMIN / "Stores" / "DoorAdminStore.swift",
                ("ControllerStatus.clampedAutoLockSeconds",),
            ),
        ),
        drift_checks=(
            (
                "iOS does not own servo clamp implementation",
                IOS_DOOR / "DoorUnlockerController.swift",
                r"private\s+static\s+func\s+clampedServoAngles",
                False,
            ),
            (
                "Mac does not own servo clamp implementation",
                MAC_ADMIN / "Stores" / "DoorAdminStore.swift",
                r"private\s+func\s+clampedServoAngles",
                False,
            ),
        ),
    ),
    Contract(
        name="controller-state-parsing",
        weight=0.22,
        shared_files=(SHARED_SOURCES / "ControllerStateParsing.swift",),
        test_files=(SHARED_TESTS / "ControllerStateParsingTests.swift",),
        minimum_test_count=5,
        ios_uses=(
            SourceUse(
                IOS_APP / "Shared" / "DoorControllerStateParser.swift",
                (
                    "DoorControllerStateParsing.fastCommandNonce",
                    "DoorControllerStateParsing.connectedDevices",
                    "DoorControllerSettingFormatting.title",
                ),
            ),
        ),
        mac_uses=(
            SourceUse(
                MAC_CORE / "ControllerStateParser.swift",
                (
                    "DoorControllerStateParsing.fastCommandNonce",
                    "DoorControllerStateParsing.connectedDevices",
                    "DoorControllerSettingFormatting.title",
                ),
            ),
        ),
        drift_checks=(
            (
                "iOS parser stays adapter-only",
                IOS_APP / "Shared" / "DoorControllerStateParser.swift",
                r"prefix:\s*\"nonce:v3:\"",
                False,
            ),
            (
                "Mac parser stays adapter-only",
                MAC_CORE / "ControllerStateParser.swift",
                r"prefix:\s*\"nonce:v3:\"",
                False,
            ),
        ),
    ),
    Contract(
        name="control-surface-presentation",
        weight=0.20,
        shared_files=(SHARED_SOURCES / "DoorControlPresentationPolicy.swift",),
        test_files=(SHARED_TESTS / "DoorControlPresentationPolicyTests.swift",),
        minimum_test_count=4,
        ios_uses=(
            SourceUse(
                IOS_DOOR / "Views" / "Components" / "LockControlButton.swift",
                (
                    "DoorControlPresentationPolicy.presentation",
                    "DoorControlPresentationInput",
                    "activationVerb: .tap",
                ),
            ),
        ),
        mac_uses=(
            SourceUse(
                MAC_ADMIN / "Views" / "Detail" / "HeroControl.swift",
                (
                    "DoorControlPresentationPolicy.presentation",
                    "DoorControlPresentationInput",
                    "activationVerb: .click",
                ),
            ),
        ),
    ),
    Contract(
        name="name-normalization",
        weight=0.14,
        shared_files=(SHARED_SOURCES / "ControllerStateParsing.swift",),
        test_files=(SHARED_TESTS / "DoorControllerPolicyTests.swift",),
        minimum_test_count=4,
        ios_uses=(
            SourceUse(IOS_DOOR / "DoorUnlockerController.swift", ("DoorControllerPolicy.sanitizedName",)),
        ),
        mac_uses=(
            SourceUse(MAC_CORE / "DoorDeviceNameNormalizer.swift", ("DoorNameNormalizer.normalized",)),
        ),
    ),
)


def app_target_uses_shared() -> dict[str, object]:
    ios_project = IOS_APP / "DoorUnlocker.xcodeproj" / "project.pbxproj"
    mac_package = MAC_PACKAGE / "Package.swift"
    checks = {
        "iOS target links DoorUnlockerShared": source_contains(ios_project, "DoorUnlockerShared"),
        "Mac package exposes shared dependency": source_contains(mac_package, ".package(path: \"../../shared/DoorUnlockerShared\")"),
        "Mac app target can import shared policy": source_contains(mac_package, "\"DoorUnlockerShared\""),
    }
    passed = sum(1 for value in checks.values() if value)
    return {
        "score": round(100 * passed / len(checks), 1),
        "passed": passed == len(checks),
        "checks": [{"name": name, "passed": value} for name, value in checks.items()],
    }


def result_payload(threshold: float) -> dict[str, object]:
    contract_results = []
    weighted_total = 0.0
    total_weight = sum(contract.weight for contract in CONTRACTS)
    for contract in CONTRACTS:
        score, checks = contract_score(contract)
        weighted_total += score * contract.weight
        contract_results.append(
            {
                "name": contract.name,
                "weight": contract.weight,
                "score": round(score, 1),
                "passed": score >= threshold,
                "checks": checks,
            }
        )

    dependency_result = app_target_uses_shared()
    score = (weighted_total / total_weight) * 0.90 + dependency_result["score"] * 0.10
    score = round(score, 1)
    passed = score >= threshold and dependency_result["passed"] and all(item["passed"] for item in contract_results)
    return {
        "score": score,
        "threshold": threshold,
        "passed": passed,
        "dependencyBoundary": dependency_result,
        "contracts": contract_results,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--threshold", type=float, default=95.0)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    payload = result_payload(args.threshold)
    if args.json:
        print(json.dumps(payload, indent=2, sort_keys=True))
    else:
        print(f"Shared parity: {payload['score']:.1f}/100")
        print(f"  dependency boundary: {payload['dependencyBoundary']['score']:.1f}/100")
        for contract in payload["contracts"]:
            print(f"  {contract['name']:29} {contract['score']:5.1f}  weight={contract['weight']:.2f}")
            for check in contract["checks"]:
                marker = "pass" if check["passed"] else "fail"
                print(f"    - {marker}: {check['name']} ({check['detail']})")
        print("  result: " + ("pass" if payload["passed"] else f"below threshold {args.threshold:.1f}"))

    return 0 if payload["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
