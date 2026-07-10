#!/usr/bin/env python3
"""Fail closed unless the current firmware package has a successful BLE OTA proof."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def current_firmware_version() -> str | None:
    source = (ROOT / "firmware/DoorUnlockerXiao/DoorUnlockerXiao.ino").read_text(encoding="utf-8")
    match = re.search(r'CONTROLLER_FIRMWARE_VERSION\[\] = "([^"]+)"', source)
    return match.group(1) if match else None


def package_payload_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with zipfile.ZipFile(path) as archive:
        names = sorted(info.filename for info in archive.infolist() if not info.is_dir())
        for name in names:
            digest.update(name.encode("utf-8"))
            digest.update(b"\0")
            digest.update(archive.read(name))
            digest.update(b"\0")
    return digest.hexdigest()


def validate_release_proof(proof: dict, firmware_version: str, package_sha256: str) -> list[str]:
    failures: list[str] = []
    package = proof.get("package", {})

    expected = {
        "result": "pass",
        "targetFirmware": firmware_version,
        "verifiedOver": "ble",
        "entryCommandOver": "ble",
        "usbRecoveryCommandUsed": False,
    }
    for key, value in expected.items():
        if proof.get(key) != value:
            failures.append(f"{key} must be {value!r}, got {proof.get(key)!r}")

    if package.get("payloadSha256") != package_sha256:
        failures.append("proof payload hash does not match the current DFU package contents")

    return failures


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--proof", type=Path, default=ROOT / "docs/firmware-release-proof.json")
    args = parser.parse_args()
    proof_path = args.proof if args.proof.is_absolute() else ROOT / args.proof
    package_path = ROOT / "dist/DoorUnlockerXiao-dfu.zip"
    bundled_package_path = ROOT / "ios/DoorUnlockerApp/DoorUnlocker/Firmware/DoorUnlockerXiao-dfu.zip"

    if not proof_path.exists() or not package_path.exists() or not bundled_package_path.exists():
        print("Firmware release proof: FAIL")
        print("- proof or DFU package is missing")
        return 1

    version = current_firmware_version()
    if not version:
        print("Firmware release proof: FAIL")
        print("- firmware version could not be read")
        return 1

    dist_payload_sha = package_payload_sha256(package_path)
    bundled_payload_sha = package_payload_sha256(bundled_package_path)
    proof = json.loads(proof_path.read_text(encoding="utf-8"))
    failures = validate_release_proof(proof, version, dist_payload_sha)
    if bundled_payload_sha != dist_payload_sha:
        failures.append("bundled iOS DFU payload does not match the dist package")
    if failures:
        print("Firmware release proof: FAIL")
        for failure in failures:
            print(f"- {failure}")
        return 1

    print(f"Firmware release proof: PASS ({version}, BLE entry and verification)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
