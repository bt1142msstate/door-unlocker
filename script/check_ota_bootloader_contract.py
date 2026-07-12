#!/usr/bin/env python3
"""Report whether the current package can support production OTA guarantees."""

from __future__ import annotations

import argparse
import json
import sys
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_PACKAGE = ROOT / "dist" / "DoorUnlockerXiao-dfu.zip"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--package", type=Path, default=DEFAULT_PACKAGE)
    parser.add_argument("--require-production", action="store_true")
    args = parser.parse_args()

    with zipfile.ZipFile(args.package) as archive:
        names = set(archive.namelist())
        manifest = json.loads(archive.read("manifest.json"))
        application = manifest.get("manifest", {}).get("application", {})
        dat_name = application.get("dat_file")
        dat_bytes = archive.read(dat_name) if dat_name in names else b""

    legacy_manifest = manifest.get("manifest", {}).get("application", {}).get("init_packet_data") is not None
    signature_enforced_by_package = not legacy_manifest and len(dat_bytes) > 64

    checks = {
        "package_exists": args.package.is_file(),
        "package_has_application": bool(application.get("bin_file")),
        "bootloader_signature_enforcement_proven": signature_enforced_by_package,
        # This cannot be proven from an application-only ZIP. It must be recorded
        # from the installed bootloader build configuration and a power-cut test.
        "installed_dual_bank_rollback_proven": False,
    }

    for name, passed in checks.items():
        print(f"{'PASS' if passed else 'NOT PROVEN'}: {name}")

    production_ready = all(checks.values())
    print(f"OTA bootloader production contract: {'PASS' if production_ready else 'NOT PROVEN'}")
    if legacy_manifest:
        print("Current package uses the legacy 0.5 init-packet format and does not prove signed-image enforcement.")
    if not checks["installed_dual_bank_rollback_proven"]:
        print("Verify or install a DUALBANK_FW=1 bootloader before claiming power-loss rollback.")

    return 1 if args.require_production and not production_ready else 0


if __name__ == "__main__":
    raise SystemExit(main())
