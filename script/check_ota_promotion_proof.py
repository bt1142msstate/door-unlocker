#!/usr/bin/env python3
"""Require content-bound BLE transitions and exact-build USB recovery proof."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_PROOF = ROOT / "docs/ota-promotion-proof.json"
DEFAULT_USB_PROOF = ROOT / "docs/usb-recovery-proof.json"
DEFAULT_MANIFEST = ROOT / "docs/firmware-signing-public-key.json"
HEX_SHA256 = re.compile(r"^[0-9a-f]{64}$")


def load(path: Path) -> dict:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    return value if isinstance(value, dict) else {}


def parse_time(value: object) -> dt.datetime | None:
    if not isinstance(value, str):
        return None
    try:
        parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    return parsed if parsed.tzinfo is not None else None


def evidence_path(value: object, root: Path) -> Path | None:
    if not isinstance(value, str) or not value:
        return None
    path = Path(value)
    return path if path.is_absolute() else root / path


def validate_transition(index: int, transition: dict, manifest: dict, root: Path) -> list[str]:
    label = f"transition {index + 1}"
    failures: list[str] = []
    if transition.get("passed") is not True:
        failures.append(f"{label} did not pass")
    if transition.get("verifiedOver") != "ble":
        failures.append(f"{label} was not verified over BLE")
    if transition.get("controllerUsbAttached") is not False:
        failures.append(f"{label} used USB during OTA proof")
    if transition.get("clientPlatform") not in {"ios", "macos"}:
        failures.append(f"{label} lacks a valid client platform")
    if transition.get("bootloaderName") != manifest.get("dfuDeviceName"):
        failures.append(f"{label} did not select the audited bootloader identity")
    if transition.get("packageProfile") != "signed-fast":
        failures.append(f"{label} did not select the signed package profile")

    start = transition.get("fromFirmware")
    target = transition.get("toFirmware")
    if not start or not target or start == target:
        failures.append(f"{label} lacks distinct version boundaries")
    for field in ("signedPackageSha256", "applicationPayloadSha256"):
        if not isinstance(transition.get(field), str) or not HEX_SHA256.fullmatch(transition[field]):
            failures.append(f"{label} lacks a valid {field}")
    if not transition.get("runId"):
        failures.append(f"{label} lacks a run ID")

    started_at = parse_time(transition.get("startedAt"))
    verified_at = parse_time(transition.get("verifiedAt"))
    stable_at = parse_time(transition.get("stableVerifiedAt"))
    if not started_at or not verified_at or not stable_at or not started_at < verified_at <= stable_at:
        failures.append(f"{label} has invalid chronological evidence")
    elif (stable_at - verified_at).total_seconds() < 15:
        failures.append(f"{label} lacks the 15-second stable post-reboot recheck")

    path = evidence_path(transition.get("evidencePath"), root)
    if path is None or not path.is_file():
        failures.append(f"{label} evidence file is missing")
    else:
        expected_hash = transition.get("evidenceSha256")
        actual_hash = hashlib.sha256(path.read_bytes()).hexdigest()
        if expected_hash != actual_hash:
            failures.append(f"{label} evidence hash does not match")
        evidence = load(path)
        if evidence.get("result") != "pass" or evidence.get("runId") != transition.get("runId"):
            failures.append(f"{label} evidence does not describe the recorded passing run")
        if evidence.get("targetFirmware") != target:
            failures.append(f"{label} evidence target does not match")
        package = evidence.get("package", {})
        if package.get("sha256") != transition.get("signedPackageSha256"):
            failures.append(f"{label} evidence package hash does not match")
        if package.get("applicationPayloadSha256") != transition.get("applicationPayloadSha256"):
            failures.append(f"{label} evidence payload hash does not match")
        if evidence.get("bootloaderName") != transition.get("bootloaderName"):
            failures.append(f"{label} evidence bootloader identity does not match")
        if evidence.get("packageProfile") != transition.get("packageProfile"):
            failures.append(f"{label} evidence package profile does not match")
    return failures


def validate(proof: dict, usb_proof: dict, manifest: dict, root: Path = ROOT) -> list[str]:
    failures: list[str] = []
    if proof.get("passed") is not True:
        failures.append("OTA promotion proof has not been finalized")
    transitions = proof.get("transitions")
    if not isinstance(transitions, list) or len(transitions) < 2:
        failures.append("at least two consecutive real OTA transitions are required")
        transitions = []
    for index, transition in enumerate(transitions):
        if not isinstance(transition, dict):
            failures.append(f"transition {index + 1} is malformed")
            continue
        failures.extend(validate_transition(index, transition, manifest, root))
    for previous, current in zip(transitions, transitions[1:]):
        if previous.get("toFirmware") != current.get("fromFirmware"):
            failures.append("OTA transitions are not consecutive")
    run_ids = [item.get("runId") for item in transitions if isinstance(item, dict)]
    if len(run_ids) != len(set(run_ids)):
        failures.append("OTA transitions reuse a run ID")
    payload_hashes = [item.get("applicationPayloadSha256") for item in transitions if isinstance(item, dict)]
    if len(payload_hashes) != len(set(payload_hashes)):
        failures.append("OTA transitions did not exercise distinct firmware payloads")

    expected_code_hash = manifest.get("bootloaderCodeArtifactSha256")
    expected_ota_hash = manifest.get("otaBootloaderArtifactSha256")
    if proof.get("bootloaderCodeArtifactSha256") != expected_code_hash:
        failures.append("OTA transition proof is not bound to the current bootloader code")
    if proof.get("otaBootloaderArtifactSha256") != expected_ota_hash:
        failures.append("OTA transition proof is not bound to the current bootloader OTA package")

    if usb_proof.get("passed") is not True:
        failures.append("physical USB recovery exercise has not passed")
    required_usb_checks = (
        "usbRecoveryVolumeMounted",
        "usbRecoveryBoardIdentityMatches",
        "usbRecoveryBuildIdentityMatches",
        "usbRecoveryVolumeReadOnly",
        "usbRecoveryWriteRejected",
        "uniqueUsbCdcSerialPresent",
        "usbHardwareIdentityPresent",
        "usbHardwareIdentityMatchesBaseline",
        "signedSerialRecoveryPassed",
        "pairingsAndSettingsPreserved",
    )
    for check in required_usb_checks:
        if usb_proof.get(check) is not True:
            failures.append(f"USB proof lacks {check}")
    if usb_proof.get("observedBootloaderBuildId") != manifest.get("usbRecoveryBuildId"):
        failures.append("USB proof is not bound to the hardware-reported bootloader build ID")
    if usb_proof.get("packageImageTypes") != ["application"]:
        failures.append("USB recovery package is not application-only")
    for field in ("signedPackageSha256", "applicationPayloadSha256", "baselineSha256"):
        value = usb_proof.get(field)
        if not isinstance(value, str) or not HEX_SHA256.fullmatch(value):
            failures.append(f"USB proof lacks a valid {field}")
    usb_device = usb_proof.get("usbDevice")
    if not isinstance(usb_device, dict) or not usb_device.get("serialNumber"):
        failures.append("USB proof lacks a unique hardware serial number")
    recovered = usb_proof.get("recoveredStatus")
    if not isinstance(recovered, dict) or recovered.get("firmware_version") != usb_proof.get("expectedFirmwareVersion"):
        failures.append("USB proof did not verify recovered firmware status")
    return failures


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--proof", type=Path, default=DEFAULT_PROOF)
    parser.add_argument("--usb-proof", type=Path, default=DEFAULT_USB_PROOF)
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    args = parser.parse_args()
    failures = validate(load(args.proof), load(args.usb_proof), load(args.manifest))
    if failures:
        print("OTA promotion recovery proof: FAIL")
        for failure in failures:
            print(f"- {failure}")
        return 1
    print("OTA promotion recovery proof: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
