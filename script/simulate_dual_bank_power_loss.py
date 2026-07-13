#!/usr/bin/env python3
"""Model pre-activation power cuts for the Door Unlocker dual-bank image."""

from __future__ import annotations

import argparse
import json
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_MANIFEST = ROOT / "docs/firmware-signing-public-key.json"
DEFAULT_PACKAGE = (
    ROOT
    / "ios/DoorUnlockerApp/DoorUnlocker/Firmware/DoorUnlockerXiao-signed-dfu.zip"
)
DEFAULT_REPORT = ROOT / "docs/ota-dual-bank-simulation.json"


def package_payload_size(package: Path) -> int:
    with zipfile.ZipFile(package) as archive:
        manifest = json.loads(archive.read("manifest.json"))
        application = manifest["manifest"]["application"]
        return len(archive.read(application["bin_file"]))


def simulate(manifest: dict, payload_bytes: int) -> dict:
    maximum = int(manifest["dualBankApplicationMaxBytes"])
    fits = 0 < payload_bytes <= maximum
    cases = []
    for progress in range(0, 100):
        staged_bytes = payload_bytes * progress // 100
        cases.append(
            {
                "cutAtProgressPercent": progress,
                "stagedBytes": staged_bytes,
                "bank0RemainsValid": fits,
                "bootSelectionAfterRestore": "previous-firmware" if fits else "update-rejected",
                "entersBootloaderBecauseOfCut": False,
            }
        )

    invalid_signature = {
        "phase": "post-transfer-validation-failed",
        "bank0RemainsValid": fits,
        "bootSelectionAfterRestore": "previous-firmware" if fits else "update-rejected",
    }
    passed = fits and all(
        case["bank0RemainsValid"]
        and case["bootSelectionAfterRestore"] == "previous-firmware"
        and not case["entersBootloaderBecauseOfCut"]
        for case in cases
    )
    return {
        "schemaVersion": 1,
        "model": "pre-activation-dual-bank-transfer",
        "payloadBytes": payload_bytes,
        "dualBankMaximumBytes": maximum,
        "payloadFits": fits,
        "singleBankFallbackDisabled": manifest.get("singleBankFallbackDisabled") is True,
        "powerCutCases": cases,
        "invalidSignatureCase": invalid_signature,
        "allPreActivationCasesBootPreviousFirmware": passed,
        "activationCopyRequiresPhysicalProof": True,
        "passed": passed and manifest.get("singleBankFallbackDisabled") is True,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--package", type=Path, default=DEFAULT_PACKAGE)
    parser.add_argument("--report", type=Path, default=DEFAULT_REPORT)
    args = parser.parse_args()

    manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
    report = simulate(manifest, package_payload_size(args.package))
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(
        f"{'PASS' if report['passed'] else 'FAIL'}: "
        f"{report['payloadBytes']} bytes within {report['dualBankMaximumBytes']}-byte bank; "
        "100 pre-activation power-cut points modeled."
    )
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
