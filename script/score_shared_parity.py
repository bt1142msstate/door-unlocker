#!/usr/bin/env python3
"""Score iOS/macOS shared-contract ownership and test registration.

This gate checks the contracts that should stay shared between the iPhone and
Mac apps. It intentionally scores cross-platform ownership, not visual sameness:
platform-specific SwiftUI can differ, but protocol, parsing, safety limits, and
control-surface presentation rules should be shared and independently tested.

This is a repository-structure heuristic, not proof that behavior passed at
runtime. `quality_suite.py` separately executes shared, iOS adapter, and Mac
adapter tests; only the combined full-suite result is behavioral parity evidence.
"""

from __future__ import annotations

import argparse
import json
import re
from dataclasses import dataclass
from pathlib import Path

from quality_test_support import count_swift_tests


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
    ios_test_files: tuple[Path, ...] = ()
    ios_minimum_test_count: int = 0
    mac_test_files: tuple[Path, ...] = ()
    mac_minimum_test_count: int = 0
    drift_checks: tuple[tuple[str, Path, str, bool], ...] = ()


def rel(path: Path) -> str:
    try:
        return str(path.relative_to(ROOT))
    except ValueError:
        return str(path)


def read(path: Path) -> str:
    if path.is_dir():
        return "\n".join(
            candidate.read_text(encoding="utf-8")
            for candidate in sorted(path.rglob("*.swift"))
        )
    return path.read_text(encoding="utf-8") if path.exists() else ""


def source_contains(path: Path, needle: str) -> bool:
    return needle in read(path)


def count_tests(paths: tuple[Path, ...]) -> int:
    return count_swift_tests(paths)


def required_source_use_passes(use: SourceUse) -> bool:
    text = read(use.path)
    return use.path.exists() and all(needle in text for needle in use.required_needles)


def regex_check(path: Path, pattern: str, expected: bool) -> bool:
    return (re.search(pattern, read(path), re.M) is not None) == expected


def contract_score(contract: Contract) -> tuple[float, list[dict[str, object]]]:
    checks: list[tuple[str, bool, str, str]] = []
    checks.append((
        "shared source exists",
        all(path.exists() for path in contract.shared_files),
        ", ".join(rel(path) for path in contract.shared_files),
        "static-structure",
    ))
    checks.append((
        "shared tests are registered for contract",
        count_tests(contract.test_files) >= contract.minimum_test_count,
        f"tests={count_tests(contract.test_files)}, minimum={contract.minimum_test_count}",
        "test-registration",
    ))
    checks.append((
        "iOS uses shared contract",
        all(required_source_use_passes(use) for use in contract.ios_uses),
        ", ".join(rel(use.path) for use in contract.ios_uses),
        "static-structure",
    ))
    checks.append((
        "Mac uses shared contract",
        all(required_source_use_passes(use) for use in contract.mac_uses),
        ", ".join(rel(use.path) for use in contract.mac_uses),
        "static-structure",
    ))

    if contract.ios_minimum_test_count:
        checks.append((
            "iOS adapter tests are registered",
            count_tests(contract.ios_test_files) >= contract.ios_minimum_test_count,
            f"tests={count_tests(contract.ios_test_files)}, minimum={contract.ios_minimum_test_count}",
            "test-registration",
        ))
    if contract.mac_minimum_test_count:
        checks.append((
            "Mac adapter tests are registered",
            count_tests(contract.mac_test_files) >= contract.mac_minimum_test_count,
            f"tests={count_tests(contract.mac_test_files)}, minimum={contract.mac_minimum_test_count}",
            "test-registration",
        ))

    for label, path, pattern, expected in contract.drift_checks:
        checks.append((label, regex_check(path, pattern, expected), rel(path), "static-structure"))

    details = [
        {
            "name": name,
            "passed": passed,
            "detail": detail,
            "evidence": evidence,
        }
        for name, passed, detail, evidence in checks
    ]
    passed = sum(1 for _, value, _, _ in checks if value)
    return 100 * passed / len(checks), details


SHARED = ROOT / "shared" / "DoorUnlockerShared"
SHARED_SOURCES = SHARED / "Sources" / "DoorUnlockerShared"
SHARED_DFU_SOURCES = SHARED / "Sources" / "DoorUnlockerDFU"
SHARED_TESTS = SHARED / "Tests" / "DoorUnlockerSharedTests"
IOS_APP = ROOT / "ios" / "DoorUnlockerApp"
IOS_DOOR = IOS_APP / "DoorUnlocker"
MAC_PACKAGE = ROOT / "mac" / "DoorUnlockerAdmin"
MAC_ADMIN = MAC_PACKAGE / "Sources" / "DoorUnlockerAdmin"
MAC_CORE = MAC_PACKAGE / "Sources" / "DoorUnlockerCore"
IOS_TESTS = IOS_APP / "DoorUnlockerTests"
MAC_TESTS = MAC_PACKAGE / "Tests" / "DoorUnlockerCoreTests"


CONTRACTS = (
    Contract(
        name="secure-command-codec",
        weight=0.24,
        shared_files=(
            SHARED_SOURCES / "DoorSecureCommandCodec.swift",
            SHARED_SOURCES / "DoorSecureCommandSigningContext.swift",
        ),
        test_files=(
            SHARED_TESTS / "DoorSecureCommandCodecTests.swift",
            SHARED_TESTS / "DoorSecureCommandSigningContextTests.swift",
        ),
        minimum_test_count=9,
        ios_uses=(
            SourceUse(
                IOS_DOOR / "DoorCommandAuthenticator.swift",
                ("DoorSecureCommandSigningContext", "signer: identity.signature"),
            ),
        ),
        mac_uses=(
            SourceUse(
                MAC_CORE / "DoorCommandAuthenticator.swift",
                ("DoorSecureCommandSigningContext", "signer: identity.signature"),
            ),
        ),
        ios_test_files=(IOS_TESTS / "DoorCommandAuthenticatorParityTests.swift",),
        ios_minimum_test_count=2,
        mac_test_files=(MAC_TESTS / "DoorCommandAuthenticatorParityTests.swift",),
        mac_minimum_test_count=2,
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
            (
                "iOS does not assemble signed wire packets",
                IOS_DOOR / "DoorCommandAuthenticator.swift",
                r"DoorSecureCommandCodec\.(unsignedPacket|messageToSign|signedPacket)",
                False,
            ),
            (
                "Mac does not assemble signed wire packets",
                MAC_CORE / "DoorCommandAuthenticator.swift",
                r"DoorSecureCommandCodec\.(unsignedPacket|messageToSign|signedPacket)",
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
                IOS_DOOR,
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
                MAC_ADMIN / "Stores",
                ("ControllerStatus.clampedAutoLockSeconds",),
            ),
        ),
        drift_checks=(
            (
                "iOS does not own servo clamp implementation",
                IOS_DOOR,
                r"private\s+static\s+func\s+clampedServoAngles",
                False,
            ),
            (
                "Mac does not own servo clamp implementation",
                MAC_ADMIN / "Stores",
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
        ios_test_files=(IOS_TESTS / "DoorControllerStateParserParityTests.swift",),
        ios_minimum_test_count=3,
        mac_test_files=(MAC_TESTS / "ControllerStateParserParityTests.swift",),
        mac_minimum_test_count=3,
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
        name="door-command-model",
        weight=0.14,
        shared_files=(SHARED_SOURCES / "DoorCommand.swift",),
        test_files=(SHARED_TESTS / "DoorCommandTests.swift",),
        minimum_test_count=3,
        ios_uses=(
            SourceUse(
                IOS_DOOR,
                ("typealias Command = DoorCommand", "DoorCommand.preparationOrder("),
            ),
        ),
        mac_uses=(
            SourceUse(
                MAC_ADMIN / "Stores",
                ("typealias Command = DoorCommand", "DoorCommand.preparationOrder("),
            ),
        ),
        drift_checks=(
            (
                "iOS does not redefine lock/unlock commands",
                IOS_DOOR,
                r"enum\s+Command\s*:\s*String",
                False,
            ),
            (
                "Mac does not redefine lock/unlock commands",
                MAC_ADMIN / "Stores",
                r"enum\s+Command\s*:\s*String",
                False,
            ),
        ),
    ),
    Contract(
        name="fast-write-dispatch",
        weight=0.18,
        shared_files=(SHARED_SOURCES / "DoorFastWritePolicy.swift",),
        test_files=(SHARED_TESTS / "DoorFastWritePolicyTests.swift",),
        minimum_test_count=6,
        ios_uses=(
            SourceUse(
                IOS_DOOR,
                (
                    "DoorFastWritePolicy.action(",
                    "DoorReliableWritePolicy.action(",
                    "peripheral.canSendWriteWithoutResponse",
                ),
            ),
        ),
        mac_uses=(
            SourceUse(
                MAC_ADMIN / "Stores",
                ("DoorFastWritePolicy.action(", "DoorReliableWritePolicy.action("),
            ),
        ),
    ),
    Contract(
        name="command-preparation-recovery",
        weight=0.16,
        shared_files=(SHARED_SOURCES / "DoorCommandPreparationRecoveryPolicy.swift",),
        test_files=(SHARED_TESTS / "DoorCommandPreparationRecoveryPolicyTests.swift",),
        minimum_test_count=4,
        ios_uses=(
            SourceUse(
                IOS_DOOR,
                ("DoorCommandPreparationRecoveryPolicy.action(",),
            ),
        ),
        mac_uses=(
            SourceUse(
                MAC_ADMIN / "Stores" / "DoorAdminStore+FastDoorRecovery.swift",
                ("DoorCommandPreparationRecoveryPolicy.action(",),
            ),
        ),
    ),
    Contract(
        name="setting-confirmation-lifecycle",
        weight=0.18,
        shared_files=(
            SHARED_SOURCES / "DoorControllerSettingOperation.swift",
            SHARED_SOURCES / "DoorControllerSettingConfirmation.swift",
            SHARED_SOURCES / "DoorControllerSettingDelay.swift",
        ),
        test_files=(
            SHARED_TESTS / "DoorControllerSettingOperationTests.swift",
            SHARED_TESTS / "DoorControllerSettingConfirmationTests.swift",
            SHARED_TESTS / "DoorControllerSettingDelayTests.swift",
        ),
        minimum_test_count=12,
        ios_uses=(
            SourceUse(
                IOS_DOOR,
                (
                    "typealias ControllerSettingOperation = DoorControllerSettingOperation",
                    "DoorSecureCommandRejection(rawReason: reason)",
                    "recoverSecureNonceAfterControllerReject()",
                    "controllerSettingConfirmation.begin(operation)",
                    "controllerSettingConfirmation.complete(operation)",
                    "DoorControllerSettingConfirmationPolicy.stateReadDelayNanoseconds",
                    "DoorControllerSettingConfirmationPolicy.completionGraceNanoseconds",
                ),
            ),
            SourceUse(
                IOS_DOOR / "Views" / "Settings" / "AutomationSettingsControls.swift",
                (
                    "onEditingChanged: { isEditing in",
                    "controller.commitAutoLockSeconds()",
                    "controller.commitServoAngles",
                ),
            ),
        ),
        mac_uses=(
            SourceUse(
                MAC_ADMIN / "Stores",
                (
                    "typealias ControllerSettingOperation = DoorControllerSettingOperation",
                    "DoorSecureCommandRejection(rawReason: reason)",
                    "recoverSecureNonceAfterControllerReject()",
                    "DoorControllerSettingDelay.inputDebounceNanoseconds",
                    "DoorControllerSettingDelay.busyRetryNanoseconds",
                    "controllerSettingConfirmation.begin(operation)",
                    "controllerSettingConfirmation.complete(operation)",
                    "DoorControllerSettingConfirmationPolicy.stateReadDelayNanoseconds",
                    "DoorControllerSettingConfirmationPolicy.completionGraceNanoseconds",
                    "DoorControllerSettingDelay.wait(",
                ),
            ),
        ),
        drift_checks=(
            (
                "iOS does not redefine setting operations",
                IOS_DOOR,
                r"enum\s+ControllerSettingOperation",
                False,
            ),
            (
                "Mac does not redefine setting operations",
                MAC_ADMIN / "Stores",
                r"enum\s+ControllerSettingOperation",
                False,
            ),
            (
                "iOS sliders do not schedule a mid-drag apply",
                IOS_DOOR,
                r"schedule(?:AutoLockTimeout|ServoAngles)Apply",
                False,
            ),
            (
                "Mac setting debounces do not swallow cancellation",
                MAC_ADMIN / "Stores",
                r"(?:autoLockApplyTask|servoAnglesApplyTask|lockNameApplyTask)\s*=\s*Task[\s\S]{0,300}?try\?\s+await\s+Task\.sleep",
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
                MAC_ADMIN / "Stores" / "DoorAdminStore+DoorControlSurface.swift",
                (
                    "DoorControlPresentationPolicy.presentation",
                    "DoorControlPresentationInput",
                    "activationVerb: .click",
                ),
            ),
            SourceUse(
                MAC_ADMIN / "Views" / "Detail" / "HeroControl.swift",
                ("store.doorControlPresentation",),
            ),
            SourceUse(
                MAC_ADMIN / "App" / "DoorUnlockerAdminApp.swift",
                (
                    "@ObservedObject private var store",
                    "store.doorControlPresentation.isPrimaryActionEnabled",
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
            SourceUse(IOS_DOOR, ("DoorControllerPolicy.sanitizedName",)),
        ),
        mac_uses=(
            SourceUse(MAC_CORE / "DoorDeviceNameNormalizer.swift", ("typealias DoorDeviceNameNormalizer = DoorNameNormalizer",)),
        ),
    ),
    Contract(
        name="firmware-dfu-transport",
        weight=0.18,
        shared_files=(
            SHARED_SOURCES / "DoorFirmwareDfuTuning.swift",
            SHARED_SOURCES / "DoorFirmwareProgressEstimation.swift",
            SHARED_DFU_SOURCES / "DoorFirmwareDfuManager.swift",
        ),
        test_files=(
            SHARED_TESTS / "DoorFirmwareDfuTuningTests.swift",
            SHARED_TESTS / "DoorFirmwareProgressEstimationTests.swift",
        ),
        minimum_test_count=7,
        ios_uses=(
            SourceUse(
                IOS_DOOR,
                (
                    "import DoorUnlockerDFU",
                    "DoorFirmwareDfuManager(",
                    "DoorFirmwareDfuUpdate",
                ),
            ),
        ),
        mac_uses=(
            SourceUse(
                MAC_ADMIN / "Stores",
                (
                    "import DoorUnlockerDFU",
                    "DoorFirmwareDfuManager(",
                    "DoorFirmwareDfuUpdate",
                ),
            ),
        ),
        drift_checks=(
            (
                "iOS does not own a DFU manager",
                IOS_DOOR / "DoorFirmwareDfuManager.swift",
                r"class\s+DoorFirmwareDfuManager",
                False,
            ),
            (
                "Mac does not own a DFU manager",
                MAC_ADMIN / "Stores" / "DoorFirmwareDfuManager.swift",
                r"class\s+DoorFirmwareDfuManager",
                False,
            ),
        ),
    ),
)


def app_target_uses_shared() -> dict[str, object]:
    ios_project = IOS_APP / "DoorUnlocker.xcodeproj" / "project.pbxproj"
    mac_package = MAC_PACKAGE / "Package.swift"
    checks = {
        "iOS target links DoorUnlockerShared": source_contains(ios_project, "DoorUnlockerShared"),
        "iOS target links DoorUnlockerDFU": source_contains(ios_project, "DoorUnlockerDFU"),
        "Mac package exposes shared dependency": source_contains(mac_package, ".package(path: \"../../shared/DoorUnlockerShared\")"),
        "Mac app target can import shared policy": source_contains(mac_package, "\"DoorUnlockerShared\""),
        "Mac app target links DoorUnlockerDFU": source_contains(mac_package, ".product(name: \"DoorUnlockerDFU\""),
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
        "scoreKind": "repository-structure-and-test-registration-heuristic",
        "score": score,
        "threshold": threshold,
        "passed": passed,
        "runtimeBehaviorVerified": False,
        "runtimeVerificationRequired": [
            "Shared package independent tests",
            "iOS adapter tests",
            "Mac core/admin independent tests",
            "iOS app build",
            "Mac app build",
        ],
        "limitations": [
            "A source reference proves shared ownership, not that a runtime branch executed.",
            "Registered test declarations only become evidence after the test runners pass.",
            "Live Bluetooth/controller behavior requires the opt-in hardware checks.",
        ],
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
        print(f"Shared parity evidence registration: {payload['score']:.1f}/100")
        print(f"  dependency boundary: {payload['dependencyBoundary']['score']:.1f}/100")
        for contract in payload["contracts"]:
            print(f"  {contract['name']:29} {contract['score']:5.1f}  weight={contract['weight']:.2f}")
            for check in contract["checks"]:
                marker = "pass" if check["passed"] else "fail"
                print(f"    - {marker}: {check['name']} ({check['detail']})")
        print("  result: " + ("pass" if payload["passed"] else f"below threshold {args.threshold:.1f}"))
        print("  runtime behavior: verified only by the full quality suite test/build steps")

    return 0 if payload["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
