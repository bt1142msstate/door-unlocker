#!/usr/bin/env python3
"""Capture and physically prove the signed USB recovery path.

Run ``--capture-baseline`` while normal firmware is connected over USB. Then
double-reset the controller and run ``--exercise --write-proof``. The second
stage binds the mounted volume to the audited bootloader build ID, verifies the
volume is read-only, performs signed CDC serial DFU, and compares persistent
controller settings with the captured baseline.
"""

from __future__ import annotations

import argparse
import datetime as dt
import glob
import hashlib
import json
import os
import plistlib
import re
import subprocess
import time
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_VOLUME = Path("/Volumes/XIAO-SENSE")
DEFAULT_PROOF = ROOT / "docs/usb-recovery-proof.json"
DEFAULT_BASELINE = ROOT / "docs/usb-recovery-baseline.json"
DEFAULT_PACKAGE = ROOT / "dist/DoorUnlockerXiao-signed-dfu.zip"
DEFAULT_NRFUTIL = (
    Path.home()
    / "Library/Arduino15/packages/Seeeduino/hardware/nrf52/1.1.13/tools/adafruit-nrfutil/macos/adafruit-nrfutil"
)
DEFAULT_CLI = ROOT / "mac/DoorUnlockerAdmin/.build/debug/door-unlocker"
EXPECTED_BOARD_ID = "nRF52840-SeeedXiaoSense-v1"
XCODE_DEVELOPER_DIR = Path("/Applications/Xcode.app/Contents/Developer")
PRESERVED_STATUS_FIELDS = (
    "lock_name",
    "paired_count",
    "auto_lock_seconds",
    "lock_angle",
    "unlock_angle",
)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def current_firmware_version() -> str:
    source = (ROOT / "firmware/DoorUnlockerXiao/DoorUnlockerXiao.ino").read_text(
        encoding="utf-8"
    )
    match = re.search(r'CONTROLLER_FIRMWARE_VERSION\[\] = "([^"]+)"', source)
    if not match:
        raise RuntimeError("Could not read the controller firmware version")
    return match.group(1)


def disk_is_read_only(volume: Path) -> bool:
    result = subprocess.run(
        ["diskutil", "info", "-plist", str(volume)],
        check=True,
        stdout=subprocess.PIPE,
    )
    info = plistlib.loads(result.stdout)
    return (
        info.get("Writable") is False
        and info.get("WritableMedia") is False
        and info.get("WritableVolume") is False
    )


def write_is_rejected(volume: Path) -> bool:
    probe = volume / ".door-unlocker-write-probe"
    try:
        probe.write_text("This write must never succeed.\n", encoding="utf-8")
    except OSError:
        return not probe.exists()
    probe.unlink(missing_ok=True)
    return False


def serial_ports() -> list[str]:
    return sorted(glob.glob("/dev/cu.usbmodem*"))


def unique_serial_port(timeout: float = 30) -> str | None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        ports = serial_ports()
        if len(ports) == 1:
            return ports[0]
        time.sleep(0.25)
    return None


def usb_identity_candidates(root: object) -> list[dict[str, str]]:
    matches: list[dict[str, str]] = []

    def visit(value: object) -> None:
        if isinstance(value, dict):
            name = str(
                value.get("_name")
                or value.get("USB Product Name")
                or value.get("kUSBProductString")
                or ""
            )
            vendor_value = value.get("vendor_id", value.get("idVendor", ""))
            vendor = (
                f"0x{vendor_value:04x}"
                if isinstance(vendor_value, int)
                else str(vendor_value)
            )
            if "xiao" in name.lower() or "239a" in vendor.lower() or "2886" in vendor.lower():
                serial = (
                    value.get("serial_num")
                    or value.get("USB Serial Number")
                    or value.get("kUSBSerialNumberString")
                )
                if serial:
                    matches.append(
                        {
                            "name": name,
                            "serialNumber": str(serial),
                            "vendorId": vendor,
                            "productId": str(value.get("product_id", value.get("idProduct", ""))),
                        }
                    )
            for child in value.values():
                visit(child)
        elif isinstance(value, list):
            for child in value:
                visit(child)

    visit(root)
    return matches


def usb_device_identity() -> dict[str, str] | None:
    result = subprocess.run(
        ["system_profiler", "SPUSBDataType", "-json"],
        check=True,
        text=True,
        stdout=subprocess.PIPE,
    )
    matches = usb_identity_candidates(json.loads(result.stdout))
    if not matches:
        registry = subprocess.run(
            ["ioreg", "-a", "-r", "-c", "IOUSBHostDevice"],
            check=True,
            stdout=subprocess.PIPE,
        )
        matches = usb_identity_candidates(plistlib.loads(registry.stdout))
    unique = {item["serialNumber"]: item for item in matches}
    return next(iter(unique.values())) if len(unique) == 1 else None


def info_uf2_fields(volume: Path) -> dict[str, str]:
    info_path = volume / "INFO_UF2.TXT"
    if not info_path.is_file():
        return {}
    fields: dict[str, str] = {}
    for line in info_path.read_text(errors="replace").splitlines():
        if ":" in line:
            key, value = line.split(":", 1)
            fields[key.strip()] = value.strip()
    return fields


def signed_package_identity(package: Path) -> dict[str, object]:
    with zipfile.ZipFile(package) as archive:
        manifest = json.loads(archive.read("manifest.json"))["manifest"]
        application = manifest["application"]
        payload = archive.read(application["bin_file"])
        return {
            "signedPackageSha256": sha256(package),
            "applicationPayloadSha256": hashlib.sha256(payload).hexdigest(),
            "applicationPayloadBytes": len(payload),
            "packageImageTypes": sorted(set(manifest) - {"dfu_version"}),
        }


def build_cli() -> None:
    environment = os.environ.copy()
    if XCODE_DEVELOPER_DIR.is_dir():
        environment["DEVELOPER_DIR"] = str(XCODE_DEVELOPER_DIR)
    swift = subprocess.run(
        ["/usr/bin/xcrun", "--find", "swift"],
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        env=environment,
    ).stdout.strip()
    subprocess.run(
        [
            swift,
            "build",
            "--package-path",
            str(ROOT / "mac/DoorUnlockerAdmin"),
            "--product",
            "door-unlocker",
        ],
        cwd=ROOT,
        check=True,
        env=environment,
        stdout=subprocess.DEVNULL,
    )


def read_controller_status(cli: Path, port: str) -> tuple[dict[str, str], str]:
    output = subprocess.run(
        [str(cli), "--port", port, "status"],
        cwd=ROOT,
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    ).stdout.strip()
    fields = dict(
        line.split("=", 1)
        for line in output.splitlines()
        if "=" in line and not line.startswith("connected_device=")
    )
    return fields, output


def capture_baseline(path: Path, cli: Path) -> int:
    port = unique_serial_port(timeout=5)
    identity = usb_device_identity()
    if port is None or identity is None:
        print("Baseline capture requires exactly one connected XIAO USB serial device.")
        return 1
    build_cli()
    status, raw = read_controller_status(cli, port)
    if status.get("firmware_version") in (None, "Unknown"):
        print("Controller did not report a valid normal-firmware status.")
        return 1
    payload = {
        "schemaVersion": 1,
        "capturedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
        "usbDevice": identity,
        "serialPort": port,
        "status": status,
        "rawStatusSha256": hashlib.sha256(raw.encode()).hexdigest(),
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    print(f"Captured USB recovery baseline at {path}")
    return 0


def exercise_signed_serial_recovery(
    nrfutil: Path,
    package: Path,
    port: str,
    cli: Path,
    expected_version: str,
) -> tuple[bool, dict[str, str], str]:
    subprocess.run(
        [str(nrfutil), "dfu", "serial", "-pkg", str(package), "-p", port, "-b", "115200"],
        cwd=ROOT,
        check=True,
    )
    build_cli()
    deadline = time.monotonic() + 45
    last_detail = "Controller did not return as the only USB serial device"
    while time.monotonic() < deadline:
        ports = serial_ports()
        if len(ports) != 1:
            time.sleep(0.5)
            continue
        try:
            status, raw = read_controller_status(cli, ports[0])
        except subprocess.CalledProcessError as error:
            last_detail = error.stdout or str(error)
            time.sleep(0.5)
            continue
        if status.get("firmware_version") == expected_version:
            return True, status, raw
        last_detail = raw
        time.sleep(0.5)
    return False, {}, last_detail


def preserved_status_matches(baseline: dict, recovered: dict[str, str]) -> bool:
    prior = baseline.get("status")
    return isinstance(prior, dict) and all(prior.get(key) == recovered.get(key) for key in PRESERVED_STATUS_FIELDS)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--volume", type=Path, default=DEFAULT_VOLUME)
    parser.add_argument("--package", type=Path, default=DEFAULT_PACKAGE)
    parser.add_argument("--nrfutil", type=Path, default=DEFAULT_NRFUTIL)
    parser.add_argument("--baseline", type=Path, default=DEFAULT_BASELINE)
    parser.add_argument("--capture-baseline", action="store_true")
    parser.add_argument("--exercise", action="store_true")
    parser.add_argument("--write-proof", action="store_true")
    parser.add_argument("--proof", type=Path, default=DEFAULT_PROOF)
    args = parser.parse_args()

    if args.capture_baseline:
        return capture_baseline(args.baseline, DEFAULT_CLI)

    manifest = json.loads((ROOT / "docs/firmware-signing-public-key.json").read_text())
    baseline = json.loads(args.baseline.read_text()) if args.baseline.is_file() else {}
    uf2 = info_uf2_fields(args.volume) if args.volume.is_dir() else {}
    ports = serial_ports()
    identity = usb_device_identity()
    checks: dict[str, bool | None] = {
        "usbRecoveryVolumeMounted": args.volume.is_dir(),
        "usbRecoveryBoardIdentityMatches": uf2.get("Board-ID") == EXPECTED_BOARD_ID,
        "usbRecoveryBuildIdentityMatches": uf2.get("Door-Bootloader-ID")
        == manifest.get("usbRecoveryBuildId"),
        "usbRecoveryVolumeReadOnly": args.volume.is_dir() and disk_is_read_only(args.volume),
        "usbRecoveryWriteRejected": args.volume.is_dir() and write_is_rejected(args.volume),
        "uniqueUsbCdcSerialPresent": len(ports) == 1,
        "usbHardwareIdentityPresent": identity is not None,
        "usbHardwareIdentityMatchesBaseline": bool(identity)
        and identity.get("serialNumber") == baseline.get("usbDevice", {}).get("serialNumber"),
    }
    expected_version = current_firmware_version()
    recovery_passed = False
    recovered_status: dict[str, str] = {}
    recovery_detail = "not exercised"
    if args.exercise and all(value is True for value in checks.values()):
        recovery_passed, recovered_status, recovery_detail = exercise_signed_serial_recovery(
            args.nrfutil,
            args.package,
            ports[0],
            DEFAULT_CLI,
            expected_version,
        )
    checks["signedSerialRecoveryPassed"] = recovery_passed if args.exercise else None
    checks["pairingsAndSettingsPreserved"] = (
        preserved_status_matches(baseline, recovered_status) if args.exercise else None
    )

    package_identity = signed_package_identity(args.package)
    payload = {
        "schemaVersion": 2,
        "generatedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
        "passed": args.exercise and all(value is True for value in checks.values()),
        "observedBoardId": uf2.get("Board-ID"),
        "observedBootloaderBuildId": uf2.get("Door-Bootloader-ID"),
        "expectedBootloaderBuildId": manifest.get("usbRecoveryBuildId"),
        "volume": str(args.volume),
        "bootloaderSerialPort": ports[0] if len(ports) == 1 else None,
        "usbDevice": identity,
        "baselineSha256": sha256(args.baseline) if args.baseline.is_file() else None,
        "expectedFirmwareVersion": expected_version,
        "recoveredStatus": recovered_status,
        "recoveryDetailSha256": hashlib.sha256(recovery_detail.encode()).hexdigest(),
        **package_identity,
        **checks,
    }
    for name, passed in checks.items():
        label = "PASS" if passed is True else "NOT EXERCISED" if passed is None else "NOT PROVEN"
        print(f"{label}: {name}")
    if args.write_proof:
        if not payload["passed"]:
            print("USB recovery proof was not written because the physical exercise did not pass.")
            return 1
        args.proof.parent.mkdir(parents=True, exist_ok=True)
        args.proof.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
        print(f"Recorded USB recovery proof at {args.proof}")
    observed = all(value is True for value in checks.values() if value is not None)
    return 0 if payload["passed"] or (not args.exercise and observed) else 1


if __name__ == "__main__":
    raise SystemExit(main())
