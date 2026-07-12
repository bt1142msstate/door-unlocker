#!/usr/bin/env python3
"""Report whether the current package can support production OTA guarantees."""

from __future__ import annotations

import argparse
import hashlib
import json
import struct
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_PACKAGE = ROOT / "ios" / "DoorUnlockerApp" / "DoorUnlocker" / "Firmware" / "DoorUnlockerXiao-dfu.zip"
DEFAULT_BOOTLOADER_MANIFEST = ROOT / "docs" / "firmware-signing-public-key.json"
DEFAULT_PUBLIC_KEY = ROOT / "docs" / "firmware-signing-public-key.pem"
DEFAULT_INSTALLED_PROOF = ROOT / "docs" / "ota-bootloader-installed-proof.json"
DEFAULT_BOOTLOADER_ARTIFACT_DIR = ROOT / "dist" / "bootloader"
BOOTLOADER_BUILD_SCRIPT = ROOT / "script" / "build_secure_bootloader.sh"
LEGACY_PACKET_SIZING = (
    ROOT
    / "vendor"
    / "IOS-DFU-Library"
    / "Library"
    / "Classes"
    / "Implementation"
    / "LegacyDFU"
    / "Characteristics"
    / "LegacyDfuPacketSizing.swift"
)
LEGACY_PACKET_WRITER = LEGACY_PACKET_SIZING.with_name("DFUPacket.swift")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--package", type=Path, default=DEFAULT_PACKAGE)
    parser.add_argument("--bootloader-manifest", type=Path, default=DEFAULT_BOOTLOADER_MANIFEST)
    parser.add_argument("--public-key", type=Path, default=DEFAULT_PUBLIC_KEY)
    parser.add_argument("--installed-proof", type=Path, default=DEFAULT_INSTALLED_PROOF)
    parser.add_argument("--require-candidate", action="store_true")
    parser.add_argument("--require-production", action="store_true")
    args = parser.parse_args()

    if not args.package.is_file():
        print(f"NOT PROVEN: package_exists ({args.package})")
        return 1 if args.require_production else 0

    with zipfile.ZipFile(args.package) as archive:
        names = set(archive.namelist())
        manifest = json.loads(archive.read("manifest.json"))
        application = manifest.get("manifest", {}).get("application", {})
        bin_name = application.get("bin_file")
        dat_name = application.get("dat_file")
        bin_bytes = archive.read(bin_name) if bin_name in names else b""
        dat_bytes = archive.read(dat_name) if dat_name in names else b""

    package_manifest = manifest.get("manifest", {})
    init_packet = application.get("init_packet_data", {})
    package_signature_fields = (
        float(package_manifest.get("dfu_version", 0)) >= 0.8
        and bool(init_packet.get("firmware_hash"))
        and bool(init_packet.get("init_packet_ecds"))
        and len(dat_bytes) > 64
    )
    package_hash_matches = (
        init_packet.get("firmware_hash") == hashlib.sha256(bin_bytes).hexdigest()
        and init_packet.get("firmware_length") == len(bin_bytes)
    )
    package_signature_valid = package_signature_fields and verify_signature(
        dat_bytes,
        init_packet.get("init_packet_ecds", ""),
        args.public_key,
    )

    bootloader_manifest = load_json(args.bootloader_manifest)
    build_script = BOOTLOADER_BUILD_SCRIPT.read_text(encoding="utf-8")
    candidate_signed = bootloader_manifest.get("signedFirmwareRequired") is True
    candidate_dual_bank = bootloader_manifest.get("dualBankFirmware") is True
    candidate_disables_unsigned_uf2 = bootloader_manifest.get("forceUnsignedUF2") is False
    candidate_public_key_matches = (
        public_key_id(args.public_key) == bootloader_manifest.get("publicKeyId")
    )
    candidate_build_flags_match = all(
        marker in build_script
        for marker in (
            'SOFTDEVICE_VERSION="7.3.0"',
            'SOFTDEVICE_FIRMWARE_ID="0x0123"',
            '-DSD_VERSION="$SOFTDEVICE_VERSION"',
            '-DDUALBANK_FW=ON',
            '-DSIGNED_FW=ON',
            "VerifyingKey.from_pem(public_key.read_text())",
        )
    ) and "-DFORCE_UF2=ON" not in build_script
    candidate_speed_profile = candidate_speed_profile_valid(bootloader_manifest)
    candidate_build_pins_speed_profile = all(
        marker in build_script
        for marker in (
            'ATT_MTU_BYTES="247"',
            'MAX_DFU_PAYLOAD_BYTES="244"',
            'GAP_EVENT_LENGTH_UNITS="12"',
            'MIN_CONNECTION_INTERVAL_MS="15"',
            'MAX_CONNECTION_INTERVAL_MS="30"',
            "opt.common_opt.conn_evt_ext.enable = 1",
            ".rx_phys = BLE_GAP_PHY_AUTO",
            "BLE_GAP_EVT_DATA_LENGTH_UPDATE_REQUEST",
            "#define SPEEDUP_FLASH_WRITES",
        )
    )
    package_softdevice_ids = [int(value) for value in init_packet.get("softdevice_req", [])]
    candidate_softdevice_id = parse_numeric_id(bootloader_manifest.get("softDeviceFirmwareId"))
    candidate_matches_package_softdevice = (
        candidate_softdevice_id is not None
        and candidate_softdevice_id in package_softdevice_ids
    )
    dual_bank_max_bytes = bootloader_manifest.get("dualBankApplicationMaxBytes")
    candidate_package_fits_dual_bank = (
        isinstance(dual_bank_max_bytes, int)
        and len(bin_bytes) <= dual_bank_max_bytes
    )
    client_packet_sizing = (
        LEGACY_PACKET_SIZING.read_text(encoding="utf-8")
        + LEGACY_PACKET_WRITER.read_text(encoding="utf-8")
    )
    client_uses_dynamic_legacy_payload = all(
        marker in client_packet_sizing
        for marker in (
            "maximumWriteValueLength",
            "adafruitMaximumPayloadBytes = 244",
            "legacyPayloadBytes = 20",
        )
    )
    migration_checks = migration_artifact_checks(
        bootloader_manifest,
        DEFAULT_BOOTLOADER_ARTIFACT_DIR,
    )

    installed_proof = load_json(args.installed_proof)
    installed_candidate = (
        installed_proof.get("passed") is True
        and installed_proof.get("bootloaderVersion") == bootloader_manifest.get("bootloaderVersion")
        and installed_proof.get("publicKeyId") == bootloader_manifest.get("publicKeyId")
        and installed_proof.get("bootloaderArtifactSha256")
        == bootloader_manifest.get("artifactSha256")
    )
    power_loss_rollback = installed_proof.get("powerLossRollbackPassed") is True
    unsigned_rejection = installed_proof.get("unsignedPackageRejected") is True
    required_power_loss_cases = {"erase", "upload-30", "upload-80", "post-validation"}
    required_app_termination_cases = {"upload-30", "upload-80"}
    power_loss_campaign_complete = required_cases_passed(
        installed_proof.get("powerLossCases"),
        required_power_loss_cases,
    )
    app_termination_campaign_complete = required_cases_passed(
        installed_proof.get("appTerminationCases"),
        required_app_termination_cases,
    )

    checks = {
        "package_exists": args.package.is_file(),
        "package_has_application": bool(application.get("bin_file")),
        "package_hash_matches_payload": package_hash_matches,
        "package_ecdsa_signature_valid": package_signature_valid,
        "candidate_requires_signed_firmware": candidate_signed,
        "candidate_uses_dual_bank": candidate_dual_bank,
        "candidate_disables_unsigned_uf2": candidate_disables_unsigned_uf2,
        "candidate_public_key_matches_manifest": candidate_public_key_matches,
        "candidate_build_flags_match_manifest": candidate_build_flags_match,
        "candidate_has_high_throughput_transport": candidate_speed_profile,
        "candidate_build_pins_high_throughput_transport": candidate_build_pins_speed_profile,
        **migration_checks,
        "candidate_matches_package_softdevice": candidate_matches_package_softdevice,
        "package_fits_candidate_dual_bank": candidate_package_fits_dual_bank,
        "client_supports_negotiated_legacy_payload": client_uses_dynamic_legacy_payload,
        "candidate_installed_and_verified": installed_candidate,
        "installed_dual_bank_rollback_proven": power_loss_rollback,
        "required_power_loss_cases_passed": power_loss_campaign_complete,
        "required_app_termination_cases_passed": app_termination_campaign_complete,
        "bluetooth_loss_recovery_passed": installed_proof.get("bluetoothLossRecoveryPassed") is True,
        "mac_wireless_update_passed": installed_proof.get("macWirelessUpdatePassed") is True,
        "pairings_and_settings_preserved": installed_proof.get("pairingsAndSettingsPreserved") is True,
        "installed_bootloader_rejects_unsigned_package": unsigned_rejection,
    }

    for name, passed in checks.items():
        print(f"{'PASS' if passed else 'NOT PROVEN'}: {name}")

    production_ready = all(checks.values())
    candidate_ready = all(
        passed
        for name, passed in checks.items()
        if name not in {
            "candidate_installed_and_verified",
            "installed_dual_bank_rollback_proven",
            "required_power_loss_cases_passed",
            "required_app_termination_cases_passed",
            "bluetooth_loss_recovery_passed",
            "mac_wireless_update_passed",
            "pairings_and_settings_preserved",
            "installed_bootloader_rejects_unsigned_package",
        }
    )
    print(f"OTA bootloader production contract: {'PASS' if production_ready else 'NOT PROVEN'}")
    if not package_signature_valid:
        print("Current package lacks a valid DFU 0.8 ECDSA signature for the recorded public key.")
    if candidate_signed and candidate_dual_bank and not installed_candidate:
        print("A signed dual-bank candidate exists, but physical installation has not been proven.")
    if not checks["installed_dual_bank_rollback_proven"]:
        print("Verify or install a DUALBANK_FW=1 bootloader before claiming power-loss rollback.")

    if args.require_production and not production_ready:
        return 1
    if args.require_candidate and not candidate_ready:
        return 1
    return 0


def load_json(path: Path) -> dict:
    if not path.is_file():
        return {}
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    return value if isinstance(value, dict) else {}


def parse_numeric_id(value: object) -> int | None:
    if isinstance(value, int):
        return value
    if not isinstance(value, str):
        return None
    try:
        return int(value, 0)
    except ValueError:
        return None


def candidate_speed_profile_valid(manifest: dict) -> bool:
    """Require the exact high-throughput BLE profile validated for this board."""
    return (
        manifest.get("attMtuBytes") == 247
        and manifest.get("maxDfuPayloadBytes") == 244
        and manifest.get("gapEventLengthUnits") == 12
        and manifest.get("minimumConnectionIntervalMs") == 15
        and manifest.get("maximumConnectionIntervalMs") == 30
        and manifest.get("dataLengthExtension") is True
        and manifest.get("automaticTwoMegabitPhy") is True
        and manifest.get("flashWritePacing") is True
    )
def migration_artifact_checks(manifest: dict, artifact_dir: Path) -> dict[str, bool]:
    artifact_name = manifest.get("migrationArtifact")
    artifact = artifact_dir / artifact_name if isinstance(artifact_name, str) else None
    exists = artifact is not None and artifact.is_file()
    if not exists:
        return {
            "migration_artifact_exists": False,
            "migration_artifact_hash_matches_manifest": False,
            "migration_uf2_structure_valid": False,
            "migration_uf2_block_map_matches_manifest": False,
            "migration_uf2_preserves_runtime_flash": False,
        }

    raw = artifact.read_bytes()
    hash_matches = hashlib.sha256(raw).hexdigest() == manifest.get("migrationArtifactSha256")
    blocks = parse_uf2_blocks(raw)
    structure_valid = blocks is not None and uf2_structure_is_valid(blocks)
    block_map_matches = structure_valid and uf2_block_map_matches_manifest(blocks, manifest)
    preserves_runtime = structure_valid and migration_preserves_runtime_flash(blocks, manifest)
    return {
        "migration_artifact_exists": True,
        "migration_artifact_hash_matches_manifest": hash_matches,
        "migration_uf2_structure_valid": structure_valid,
        "migration_uf2_block_map_matches_manifest": block_map_matches,
        "migration_uf2_preserves_runtime_flash": preserves_runtime,
    }


def parse_uf2_blocks(raw: bytes) -> list[tuple[int, int, int, int, int, int]] | None:
    if not raw or len(raw) % 512 != 0:
        return None
    blocks = []
    for offset in range(0, len(raw), 512):
        block = raw[offset:offset + 512]
        magic0, magic1, flags, address, size, number, total, family = struct.unpack_from(
            "<IIIIIIII", block, 0
        )
        magic_end = struct.unpack_from("<I", block, 508)[0]
        if (magic0, magic1, magic_end) != (0x0A324655, 0x9E5D5157, 0x0AB16F30):
            return None
        if size <= 0 or size > 476:
            return None
        blocks.append((address, address + size, flags, family, number, total))
    return blocks


def uf2_structure_is_valid(blocks: list[tuple[int, int, int, int, int, int]]) -> bool:
    if not blocks:
        return False
    addresses = [start for start, *_ in blocks]
    numbers = [number for *_, number, _ in blocks]
    totals = [total for *_, total in blocks]
    ordered = sorted((start, end) for start, end, *_ in blocks)
    no_overlap = all(previous_end <= start for (_, previous_end), (start, _) in zip(ordered, ordered[1:]))
    return (
        len(addresses) == len(set(addresses))
        and sorted(numbers) == list(range(len(blocks)))
        and set(totals) == {len(blocks)}
        and no_overlap
    )


def uf2_address_ranges(
    blocks: list[tuple[int, int, int, int, int, int]],
) -> list[tuple[int, int]]:
    ranges: list[tuple[int, int]] = []
    for start, end in sorted((start, end) for start, end, *_ in blocks):
        if ranges and ranges[-1][1] == start:
            ranges[-1] = (ranges[-1][0], end)
        else:
            ranges.append((start, end))
    return ranges


def uf2_block_map_matches_manifest(
    blocks: list[tuple[int, int, int, int, int, int]],
    manifest: dict,
) -> bool:
    expected_ranges = manifest.get("migrationAddressRanges")
    if not isinstance(expected_ranges, list):
        return False
    parsed_ranges = []
    for value in expected_ranges:
        if not isinstance(value, dict):
            return False
        start = parse_numeric_id(value.get("start"))
        end = parse_numeric_id(value.get("endExclusive"))
        if start is None or end is None or value.get("bytes") != end - start:
            return False
        parsed_ranges.append((start, end))
    expected_family = parse_numeric_id(manifest.get("migrationFamilyId"))
    return (
        manifest.get("migrationBlockCount") == len(blocks)
        and expected_family == 0xD663823C
        and all(flags & 0x2000 and family == expected_family for _, _, flags, family, _, _ in blocks)
        and uf2_address_ranges(blocks) == parsed_ranges
    )


def migration_preserves_runtime_flash(
    blocks: list[tuple[int, int, int, int, int, int]],
    manifest: dict,
) -> bool:
    bootloader_start = parse_numeric_id(manifest.get("bootloaderStartAddress"))
    application_start = parse_numeric_id(manifest.get("applicationStartAddress"))
    if bootloader_start is None or application_start is None:
        return False

    def allowed(start: int, end: int) -> bool:
        return (
            (0 <= start < end <= 0x1000)
            or (bootloader_start <= start < end <= 0x100000)
            or (0x10001000 <= start < end <= 0x10002000)
        )

    ranges = uf2_address_ranges(blocks)
    return (
        application_start == 0x27000
        and all(allowed(start, end) for start, end, *_ in blocks)
        and any(start == 0 for start, _ in ranges)
        and any(start == bootloader_start for start, _ in ranges)
        and any(0xFD000 <= start < 0x100000 for start, _ in ranges)
        and any(start == 0x10001000 for start, _ in ranges)
    )


def public_key_id(public_key: Path) -> str | None:
    if not public_key.is_file():
        return None
    result = subprocess.run(
        ["openssl", "pkey", "-pubin", "-in", str(public_key), "-outform", "DER"],
        capture_output=True,
        check=False,
    )
    der = result.stdout
    if result.returncode != 0 or len(der) < 65 or der[-65] != 0x04:
        return None
    return hashlib.sha256(der[-64:]).hexdigest()


def required_cases_passed(value: object, required: set[str]) -> bool:
    if not isinstance(value, list):
        return False
    passed = {
        item.get("phase")
        for item in value
        if isinstance(item, dict)
        and item.get("passed") is True
        and evidence_path_exists(item.get("report"))
    }
    return required.issubset(passed)


def evidence_path_exists(value: object) -> bool:
    if not isinstance(value, str) or not value:
        return False
    path = Path(value)
    return (path if path.is_absolute() else ROOT / path).is_file()


def verify_signature(dat_bytes: bytes, manifest_signature: str, public_key: Path) -> bool:
    if len(dat_bytes) < 65 or not public_key.is_file():
        return False
    raw_signature = dat_bytes[-64:]
    if raw_signature.hex() != manifest_signature.lower():
        return False
    der_signature = encode_der_signature(raw_signature)
    with tempfile.TemporaryDirectory() as directory:
        directory_path = Path(directory)
        payload = directory_path / "init-packet.bin"
        signature = directory_path / "signature.der"
        payload.write_bytes(dat_bytes[:-64])
        signature.write_bytes(der_signature)
        result = subprocess.run(
            [
                "openssl",
                "dgst",
                "-sha256",
                "-verify",
                str(public_key),
                "-signature",
                str(signature),
                str(payload),
            ],
            capture_output=True,
            text=True,
            check=False,
        )
    return result.returncode == 0


def encode_der_signature(raw_signature: bytes) -> bytes:
    if len(raw_signature) != 64:
        raise ValueError("P-256 signature must contain 64 bytes")

    def integer(value: bytes) -> bytes:
        value = value.lstrip(b"\0") or b"\0"
        if value[0] & 0x80:
            value = b"\0" + value
        return b"\x02" + bytes([len(value)]) + value

    encoded = integer(raw_signature[:32]) + integer(raw_signature[32:])
    return b"\x30" + bytes([len(encoded)]) + encoded


if __name__ == "__main__":
    raise SystemExit(main())
