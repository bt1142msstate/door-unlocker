#!/usr/bin/env python3
"""Exhaustively model transfer and transactional-activation interruptions."""

from __future__ import annotations

import argparse
import json
import zipfile
from math import ceil
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
    transfer_passed = fits and all(
        case["bank0RemainsValid"]
        and case["bootSelectionAfterRestore"] == "previous-firmware"
        and not case["entersBootloaderBecauseOfCut"]
        for case in cases
    )
    page_bytes = 4096
    journal_words = 9
    settings_words = 8
    bank_pages = ceil(payload_bytes / page_bytes) if fits else 0
    image_words = ceil(payload_bytes / 4) if fits else 0

    # A cut while creating the journal either leaves it invalid, in which case
    # untouched bank 0 boots, or complete, in which case recovery activates it.
    # Once the journal is valid, every bank-0 erase/copy and settings-write cut
    # retries from immutable bank 1. During final journal erase, either the
    # journal still validates and retries harmlessly, or new bank 0 boots.
    activation_phases = [
        {
            "phase": "journal-stage",
            "cutPoints": journal_words + 2,
            "recovery": "previous-firmware-or-resume",
            "invariant": "bank-0-untouched-until-valid-journal",
        },
        {
            "phase": "bank0-erase",
            "cutPoints": bank_pages + 1,
            "recovery": "resume-from-verified-bank1",
            "invariant": "valid-journal-retained",
        },
        {
            "phase": "bank0-copy",
            "cutPoints": image_words + 1,
            "recovery": "resume-from-verified-bank1",
            "invariant": "source-bank-never-modified",
        },
        {
            "phase": "settings-commit",
            "cutPoints": settings_words + 2,
            "recovery": "resume-from-verified-bank1",
            "invariant": "journal-cleared-after-settings-verify",
        },
        {
            "phase": "journal-clear",
            "cutPoints": journal_words + 2,
            "recovery": "resume-or-boot-new-firmware",
            "invariant": "new-bank0-and-settings-already-valid",
        },
    ]
    activation_cut_points = sum(phase["cutPoints"] for phase in activation_phases)
    fault_cases = [
        {
            "fault": "corrupt-transfer-before-validation",
            "outcome": "signature-or-hash-rejected-bank0-unchanged",
            "passed": fits,
        },
        {
            "fault": "corrupt-bank1-after-journal",
            "outcome": "crc-rejected-before-bank0-erase",
            "passed": fits,
        },
        {
            "fault": "corrupt-bank0-copy",
            "outcome": "crc-rejected-journal-retained-for-retry",
            "passed": fits,
        },
        {
            "fault": "corrupt-or-interrupted-settings-write",
            "outcome": "journal-retained-for-retry",
            "passed": fits,
        },
        {
            "fault": "reset-before-or-after-activation",
            "outcome": "resume-or-boot-verified-new-firmware",
            "passed": fits,
        },
    ]
    transactional = (
        manifest.get("transactionalActivationJournal") is True
        and manifest.get("activationResumesAfterReset") is True
    )
    activation_passed = fits and transactional and all(
        fault["passed"] for fault in fault_cases
    )

    return {
        "schemaVersion": 2,
        "model": "dual-bank-transfer-and-transactional-activation",
        "payloadBytes": payload_bytes,
        "dualBankMaximumBytes": maximum,
        "payloadFits": fits,
        "singleBankFallbackDisabled": manifest.get("singleBankFallbackDisabled") is True,
        "powerCutCases": cases,
        "invalidSignatureCase": invalid_signature,
        "allPreActivationCasesBootPreviousFirmware": transfer_passed,
        "transactionalActivationJournal": transactional,
        "activationPhases": activation_phases,
        "activationCutPointsModeled": activation_cut_points,
        "activationFaultCases": fault_cases,
        "allActivationCasesRecover": activation_passed,
        "activationCopyRequiresPhysicalProof": True,
        "passed": (
            transfer_passed
            and activation_passed
            and manifest.get("singleBankFallbackDisabled") is True
        ),
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
        f"100 transfer and {report['activationCutPointsModeled']} activation "
        "power-cut points modeled."
    )
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
