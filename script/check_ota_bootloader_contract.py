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
DEFAULT_PACKAGE = ROOT / "ios" / "DoorUnlockerApp" / "DoorUnlocker" / "Firmware" / "DoorUnlockerXiao-signed-dfu.zip"
DEFAULT_LEGACY_PACKAGE = ROOT / "ios" / "DoorUnlockerApp" / "DoorUnlocker" / "Firmware" / "DoorUnlockerXiao-dfu.zip"
DEFAULT_BOOTLOADER_MANIFEST = ROOT / "docs" / "firmware-signing-public-key.json"
DEFAULT_PUBLIC_KEY = ROOT / "docs" / "firmware-signing-public-key.pem"
DEFAULT_INSTALLED_PROOF = ROOT / "docs" / "ota-bootloader-installed-proof.json"
DEFAULT_USB_RECOVERY_PROOF = ROOT / "docs" / "usb-recovery-proof.json"
DEFAULT_REPRODUCIBILITY_PROOF = ROOT / "docs" / "bootloader-reproducibility-proof.json"
DEFAULT_BOOTLOADER_ARTIFACT_DIR = ROOT / "dist" / "bootloader"
DEFAULT_APPLICATION_UF2 = ROOT / "dist" / "DoorUnlockerXiao.uf2"
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
LEGACY_DFU_SERVICE = (
    LEGACY_PACKET_SIZING.parent.parent / "Services" / "LegacyDFUService.swift"
)
DFU_TUNING = ROOT / "shared" / "DoorUnlockerShared" / "Sources" / "DoorUnlockerShared" / "DoorFirmwareDfuTuning.swift"
DFU_MANAGER = ROOT / "shared" / "DoorUnlockerShared" / "Sources" / "DoorUnlockerDFU" / "DoorFirmwareDfuManager.swift"
BOOTLOADER_PATCHER = ROOT / "script/patch_secure_bootloader.py"
OTA_MEMORY_LAYOUT = ROOT / "firmware/DoorUnlockerXiao/OtaMemoryLayout.h"
FIRMWARE_BUILD_SCRIPT = ROOT / "script/flash_xiao_uf2.sh"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--package", type=Path, default=DEFAULT_PACKAGE)
    parser.add_argument("--legacy-package", type=Path, default=DEFAULT_LEGACY_PACKAGE)
    parser.add_argument("--bootloader-manifest", type=Path, default=DEFAULT_BOOTLOADER_MANIFEST)
    parser.add_argument("--public-key", type=Path, default=DEFAULT_PUBLIC_KEY)
    parser.add_argument("--installed-proof", type=Path, default=DEFAULT_INSTALLED_PROOF)
    parser.add_argument(
        "--usb-recovery-proof", type=Path, default=DEFAULT_USB_RECOVERY_PROOF
    )
    parser.add_argument(
        "--reproducibility-proof", type=Path, default=DEFAULT_REPRODUCIBILITY_PROOF
    )
    parser.add_argument("--require-candidate", action="store_true")
    parser.add_argument("--require-firmware-artifacts", action="store_true")
    parser.add_argument("--require-release-invariant", action="store_true")
    parser.add_argument("--require-installed-recovery", action="store_true")
    parser.add_argument("--require-ota-package", action="store_true")
    parser.add_argument("--require-production", action="store_true")
    args = parser.parse_args()

    if not args.package.is_file():
        print(f"NOT PROVEN: package_exists ({args.package})")
        return 1 if any(
            (
                args.require_candidate,
                args.require_firmware_artifacts,
                args.require_release_invariant,
                args.require_installed_recovery,
                args.require_ota_package,
                args.require_production,
            )
        ) else 0

    manifest, application, bin_bytes, dat_bytes = read_dfu_package(args.package)
    legacy_manifest, legacy_application, legacy_bin_bytes, legacy_dat_bytes = read_dfu_package(
        args.legacy_package
    )

    package_manifest = manifest.get("manifest", {})
    signed_package_preserves_bootloader = application_package_only(package_manifest)
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
    legacy_init_packet = legacy_application.get("init_packet_data", {})
    legacy_package_manifest = legacy_manifest.get("manifest", {})
    factory_package_preserves_bootloader = application_package_only(legacy_package_manifest)
    legacy_package_format_valid = (
        args.legacy_package.is_file()
        and float(legacy_manifest.get("manifest", {}).get("dfu_version", 1)) < 0.8
        and isinstance(legacy_init_packet.get("firmware_crc16"), int)
        and not legacy_init_packet.get("init_packet_ecds")
        and len(legacy_dat_bytes) <= 32
    )
    package_payloads_match = bool(bin_bytes) and bin_bytes == legacy_bin_bytes

    bootloader_manifest = load_json(args.bootloader_manifest)
    build_script = BOOTLOADER_BUILD_SCRIPT.read_text(encoding="utf-8")
    bootloader_patcher = BOOTLOADER_PATCHER.read_text(encoding="utf-8")
    ota_memory_layout = OTA_MEMORY_LAYOUT.read_text(encoding="utf-8")
    firmware_build_script = FIRMWARE_BUILD_SCRIPT.read_text(encoding="utf-8")
    candidate_signed = bootloader_manifest.get("signedFirmwareRequired") is True
    candidate_dual_bank = bootloader_manifest.get("dualBankFirmware") is True
    candidate_disables_unsigned_uf2 = (
        bootloader_manifest.get("forceUnsignedUF2") is False
        and bootloader_manifest.get("usbRecoveryVolumeReadOnly") is True
    )
    candidate_wireless_invalid_app_recovery = candidate_fault_tolerance_profile_valid(
        bootloader_manifest
    )
    candidate_application_write_protection = (
        bootloader_manifest.get("applicationFlashWriteProtection") == "ACL"
        and bootloader_manifest.get("mbrWriteProtectedFromApplication") is True
        and bootloader_manifest.get("bootloaderWriteProtectedFromApplication") is True
        and all(
            marker in build_script
            for marker in (
                '#error "Door Unlocker requires nRF52840 ACL flash protection"',
                "bootloader_util_flash_protect(0, MBR_SIZE);",
                "bootloader_util_flash_protect(BOOTLOADER_REGION_START, area_size);",
                "Built bootloader does not link application flash protection.",
            )
        )
    )
    candidate_upstream_activation = upstream_activation_contract_valid(
        bootloader_manifest, build_script, bootloader_patcher
    )
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
            '-DDEFAULT_TO_OTA_DFU="$DEFAULT_TO_OTA_DFU"',
            '-DFORCE_UF2=ON',
            '-DSIGNED_FW=ON',
            "Could not uniquely preserve double-reset USB recovery",
            "if (!valid_app && !dfu_start)",
            "VerifyingKey.from_pem(public_key.read_text())",
            'm_functions.activate = dfu_activate_app;',
            '"usbMassStorageRecoveryVolume": True',
            '"usbRecoveryVolumeReadOnly": True',
            '"usbCdcSignedRecovery": True',
        )
    )
    candidate_usb_recovery_is_fail_closed = all(
        marker in bootloader_patcher
        for marker in (
            "bool tud_msc_is_writable_cb(uint8_t lun)",
            "return false;",
            "read-only signed USB recovery volume",
        )
    )
    candidate_usb_recovery_has_build_identity = (
        isinstance(bootloader_manifest.get("usbRecoveryBuildId"), str)
        and len(bootloader_manifest["usbRecoveryBuildId"]) == 20
        and 'BOOTLOADER_UPSTREAM_COMMIT="c67f0bcf0fa8e841426335b1bbde91cda6ca1f50"'
        in build_script
        and "Door-Bootloader-ID:" in bootloader_patcher
    )
    candidate_build_identity_is_content_bound = (
        bootloader_manifest.get("buildScriptSha256")
        == hashlib.sha256(BOOTLOADER_BUILD_SCRIPT.read_bytes()).hexdigest()
        and bootloader_manifest.get("patcherSha256")
        == hashlib.sha256(BOOTLOADER_PATCHER.read_bytes()).hexdigest()
        and isinstance(bootloader_manifest.get("sourceDateEpoch"), int)
        and isinstance(bootloader_manifest.get("armGccVersion"), str)
        and isinstance(bootloader_manifest.get("cmakeVersion"), str)
        and "export SOURCE_DATE_EPOCH TZ=UTC LC_ALL=C" in build_script
        and '"$BUILD_SCRIPT_SHA256"' in build_script
        and '"$PATCHER_SHA256"' in build_script
        and bootloader_manifest.get("usbRecoveryBuildId")
        == expected_recovery_build_id(bootloader_manifest)
    )
    candidate_speed_profile = candidate_speed_profile_valid(bootloader_manifest)
    candidate_build_pins_speed_profile = all(
        marker in build_script
        for marker in (
            'ATT_MTU_BYTES="247"',
            'MAX_DFU_PAYLOAD_BYTES="244"',
            'GAP_EVENT_LENGTH_UNITS="12"',
            'MIN_CONNECTION_INTERVAL_MS="${DOOR_BOOTLOADER_MIN_CONNECTION_INTERVAL_MS:-15}"',
            'MAX_CONNECTION_INTERVAL_MS="${DOOR_BOOTLOADER_MAX_CONNECTION_INTERVAL_MS:-15}"',
            'CANDIDATE_DFU_DEVICE_NAME="DoorDFUStable"',
            "opt.common_opt.conn_evt_ext.enable = 1",
            ".rx_phys = $PHY_SOURCE_CONSTANT",
            "BLE_GAP_EVT_DATA_LENGTH_UPDATE_REQUEST",
            "#define SPEEDUP_FLASH_WRITES",
        )
    ) and all(
        marker in bootloader_patcher
        for marker in (
            "dfu_region_is_erased",
            "DFU_BANK_1_REGION_START",
            "pstorage_callback_handler(",
        )
    ) and all(
        marker in ota_memory_layout
        for marker in (
            "OTA_APPLICATION_START = 0x27000",
            "OTA_DUAL_BANK_APPLICATION_BYTES = 397312",
            "OTA_STAGING_BANK_START",
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
        + LEGACY_DFU_SERVICE.read_text(encoding="utf-8")
        + DFU_TUNING.read_text(encoding="utf-8")
        + DFU_MANAGER.read_text(encoding="utf-8")
    )
    client_uses_dynamic_legacy_payload = all(
        marker in client_packet_sizing
        for marker in (
            "maximumWriteValueLength",
            "adafruitMaximumPayloadBytes = 244",
            "legacyPayloadBytes = 20",
            'factoryBootloaderName = "AdaDFU"',
            'optimizedBootloaderName = "DoorDFU"',
            "isOptimizedBootloaderName",
            "resolvedBootloaderName(",
            "cachedPeripheralName: peripheral.name",
            "return packetReceiptNotificationParameter",
            ".packetReceiptNotificationParameter(forBootloaderNamed: bootloaderName)",
            "signedPackageURL",
            "packageURL(forBootloaderNamed: bootloaderName)",
            "packetsToSendNow = min(UInt32(prnValue), packetsLeft)",
            "guard canSendPacket || prnValue > 0 else",
            "If PRNs are enabled we will ignore the new API",
        )
    )
    migration_checks = migration_artifact_checks(
        bootloader_manifest,
        DEFAULT_BOOTLOADER_ARTIFACT_DIR,
    )
    bootloader_ota_checks = bootloader_ota_artifact_checks(
        bootloader_manifest,
        DEFAULT_BOOTLOADER_ARTIFACT_DIR,
        args.public_key,
    )
    application_uf2_checks = application_uf2_artifact_checks(
        DEFAULT_APPLICATION_UF2,
        bootloader_manifest,
    )
    firmware_build_enforces_application_ranges = (
        'script/check_ota_bootloader_contract.py" --require-firmware-artifacts'
        in firmware_build_script
    )

    installed_proof = load_json(args.installed_proof)
    usb_recovery_proof = load_json(args.usb_recovery_proof)
    reproducibility_proof = load_json(args.reproducibility_proof)
    candidate_reproducibility_proven = reproducibility_proof_matches(
        reproducibility_proof, bootloader_manifest
    )
    exact_usb_recovery_proven = usb_recovery_proof_matches(
        usb_recovery_proof,
        installed_proof,
        bootloader_manifest,
        args.usb_recovery_proof,
    )
    installed_candidate = (
        installed_proof.get("passed") is True
        and installed_proof.get("bootloaderVersion") == bootloader_manifest.get("bootloaderVersion")
        and installed_proof.get("publicKeyId") == bootloader_manifest.get("publicKeyId")
        and installed_proof.get("bootloaderArtifactSha256")
        == bootloader_manifest.get("artifactSha256")
        and installed_proof.get("bootloaderCodeArtifactSha256")
        == bootloader_manifest.get("bootloaderCodeArtifactSha256")
        and installed_proof.get("otaBootloaderArtifactSha256")
        == bootloader_manifest.get("otaBootloaderArtifactSha256")
        and exact_usb_recovery_proven
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
        "signed_application_package_preserves_bootloader": signed_package_preserves_bootloader,
        "factory_application_package_preserves_bootloader": factory_package_preserves_bootloader,
        "package_hash_matches_payload": package_hash_matches,
        "package_ecdsa_signature_valid": package_signature_valid,
        "factory_package_uses_legacy_crc_format": legacy_package_format_valid,
        "factory_and_signed_payloads_match": package_payloads_match,
        "candidate_requires_signed_firmware": candidate_signed,
        "candidate_uses_dual_bank": candidate_dual_bank,
        "candidate_disables_unsigned_uf2": candidate_disables_unsigned_uf2,
        "candidate_mounts_read_only_usb_recovery_volume": candidate_usb_recovery_is_fail_closed,
        "candidate_usb_recovery_reports_exact_build_identity": candidate_usb_recovery_has_build_identity,
        "candidate_build_identity_is_content_bound": candidate_build_identity_is_content_bound,
        "candidate_reproducibility_proven": candidate_reproducibility_proven,
        "candidate_defaults_invalid_app_recovery_to_ble": candidate_wireless_invalid_app_recovery,
        "candidate_protects_mbr_and_bootloader_from_application_writes": candidate_application_write_protection,
        "candidate_uses_upstream_persisted_activation": candidate_upstream_activation,
        "candidate_public_key_matches_manifest": candidate_public_key_matches,
        "candidate_build_flags_match_manifest": candidate_build_flags_match,
        "candidate_has_high_throughput_transport": candidate_speed_profile,
        "candidate_build_pins_high_throughput_transport": candidate_build_pins_speed_profile,
        **migration_checks,
        **bootloader_ota_checks,
        **application_uf2_checks,
        "firmware_build_enforces_application_ranges": firmware_build_enforces_application_ranges,
        "candidate_matches_package_softdevice": candidate_matches_package_softdevice,
        "package_fits_candidate_dual_bank": candidate_package_fits_dual_bank,
        "client_supports_negotiated_legacy_payload": client_uses_dynamic_legacy_payload,
        "candidate_installed_and_verified": installed_candidate,
        "exact_usb_recovery_proven": exact_usb_recovery_proven,
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
    release_invariant_names = {
        "package_exists",
        "package_has_application",
        "signed_application_package_preserves_bootloader",
        "factory_application_package_preserves_bootloader",
        "package_hash_matches_payload",
        "package_ecdsa_signature_valid",
        "factory_package_uses_legacy_crc_format",
        "factory_and_signed_payloads_match",
        "candidate_requires_signed_firmware",
        "candidate_uses_dual_bank",
        "candidate_disables_unsigned_uf2",
        "candidate_mounts_read_only_usb_recovery_volume",
        "candidate_usb_recovery_reports_exact_build_identity",
        "candidate_build_identity_is_content_bound",
        "candidate_defaults_invalid_app_recovery_to_ble",
        "candidate_protects_mbr_and_bootloader_from_application_writes",
        "candidate_uses_upstream_persisted_activation",
        "candidate_public_key_matches_manifest",
        "candidate_build_flags_match_manifest",
        "ota_bootloader_artifact_exists",
        "ota_bootloader_artifact_hash_matches_manifest",
        "ota_bootloader_package_has_only_bootloader",
        "ota_bootloader_payload_matches_candidate",
        "ota_bootloader_compiled_recovery_identities_present",
        "ota_bootloader_package_signature_valid",
        "ota_bootloader_package_softdevice_matches",
        "ota_bootloader_package_hardware_revision_matches",
        "candidate_matches_package_softdevice",
        "package_fits_candidate_dual_bank",
        "firmware_build_enforces_application_ranges",
    }
    release_invariant_ready = all(checks[name] for name in release_invariant_names)
    firmware_artifact_names = {
        "package_exists",
        "package_has_application",
        "signed_application_package_preserves_bootloader",
        "factory_application_package_preserves_bootloader",
        "package_hash_matches_payload",
        "package_ecdsa_signature_valid",
        "factory_package_uses_legacy_crc_format",
        "factory_and_signed_payloads_match",
        "application_uf2_exists",
        "application_uf2_structure_valid",
        "application_uf2_preserves_bootloader",
        "candidate_matches_package_softdevice",
        "package_fits_candidate_dual_bank",
    }
    firmware_artifacts_ready = all(checks[name] for name in firmware_artifact_names)
    candidate_ready = all(
        passed
        for name, passed in checks.items()
        if name not in {
            "candidate_installed_and_verified",
            "exact_usb_recovery_proven",
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
    print(
        "Per-release recovery-preservation invariant: "
        f"{'PASS' if release_invariant_ready else 'FAIL'}"
    )
    print(
        "Generated firmware artifacts preserve recovery: "
        f"{'PASS' if firmware_artifacts_ready else 'FAIL'}"
    )
    if not package_signature_valid:
        print("Current package lacks a valid DFU 0.8 ECDSA signature for the recorded public key.")
    if candidate_signed and candidate_dual_bank and not installed_candidate:
        print("A signed dual-bank candidate exists, but physical installation has not been proven.")
    if not checks["installed_dual_bank_rollback_proven"]:
        if installed_candidate:
            print("Complete the required erase and post-validation physical interruption cases before claiming production rollback.")
        else:
            print("Verify or install a DUALBANK_FW=1 bootloader before claiming power-loss rollback.")

    if args.require_production and not production_ready:
        return 1
    if args.require_candidate and not candidate_ready:
        return 1
    if args.require_firmware_artifacts and not firmware_artifacts_ready:
        return 1
    if args.require_release_invariant and not release_invariant_ready:
        return 1
    if args.require_installed_recovery and not (
        installed_candidate and exact_usb_recovery_proven
    ):
        return 1
    if args.require_ota_package and not all(bootloader_ota_checks.values()):
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


def usb_recovery_proof_matches(
    proof: dict,
    installed_proof: dict,
    manifest: dict,
    proof_path: Path,
) -> bool:
    if not proof_path.is_file():
        return False
    expected_hash = installed_proof.get("usbRecoveryProofSha256")
    return (
        proof.get("passed") is True
        and proof.get("observedBootloaderBuildId") == manifest.get("usbRecoveryBuildId")
        and proof.get("expectedBootloaderBuildId") == manifest.get("usbRecoveryBuildId")
        and proof.get("usbRecoveryBuildIdentityMatches") is True
        and proof.get("usbRecoveryVolumeMounted") is True
        and proof.get("usbRecoveryVolumeReadOnly") is True
        and proof.get("usbRecoveryWriteRejected") is True
        and proof.get("signedSerialRecoveryPassed") is True
        and proof.get("pairingsAndSettingsPreserved") is True
        and proof.get("packageImageTypes") == ["application"]
        and isinstance(expected_hash, str)
        and hashlib.sha256(proof_path.read_bytes()).hexdigest() == expected_hash
    )


def expected_recovery_build_id(manifest: dict) -> str:
    values = (
        "door-unlocker-recovery-v1",
        manifest.get("bootloaderUpstreamCommit"),
        manifest.get("board"),
        manifest.get("softDeviceVersion"),
        manifest.get("publicKeyId"),
        manifest.get("minimumConnectionIntervalMs"),
        manifest.get("maximumConnectionIntervalMs"),
        manifest.get("flashWriteLocalLatencyEvents"),
        manifest.get("phyPreference"),
        manifest.get("hciRxQueueSize"),
        manifest.get("pstorageQueueSize"),
        manifest.get("sourceDateEpoch"),
        manifest.get("armGccVersion"),
        manifest.get("cmakeVersion"),
        manifest.get("buildScriptSha256"),
        manifest.get("patcherSha256"),
    )
    if any(value is None for value in values):
        return ""
    encoded = "".join(f"{value}\n" for value in values).encode()
    return hashlib.sha256(encoded).hexdigest()[:20]


def reproducibility_proof_matches(proof: dict, manifest: dict) -> bool:
    artifact_hashes = proof.get("artifactHashes")
    return (
        proof.get("passed") is True
        and proof.get("usbRecoveryBuildId") == manifest.get("usbRecoveryBuildId")
        and proof.get("bootloaderUpstreamCommit") == manifest.get("bootloaderUpstreamCommit")
        and proof.get("sourceDateEpoch") == manifest.get("sourceDateEpoch")
        and proof.get("buildScriptSha256") == manifest.get("buildScriptSha256")
        and proof.get("patcherSha256") == manifest.get("patcherSha256")
        and isinstance(artifact_hashes, dict)
        and artifact_hashes.get("artifact") == manifest.get("artifactSha256")
        and artifact_hashes.get("migrationArtifact") == manifest.get("migrationArtifactSha256")
        and artifact_hashes.get("bootloaderCodeArtifact")
        == manifest.get("bootloaderCodeArtifactSha256")
        and artifact_hashes.get("otaBootloaderArtifact")
        == manifest.get("otaBootloaderArtifactSha256")
    )


def application_package_only(package_manifest: dict) -> bool:
    """Application releases must never include MBR, SoftDevice, or bootloader images."""
    return set(package_manifest) == {"application", "dfu_version"}


def application_uf2_artifact_checks(path: Path, manifest: dict) -> dict[str, bool]:
    checks = {
        "application_uf2_exists": path.is_file(),
        "application_uf2_structure_valid": False,
        "application_uf2_preserves_bootloader": False,
    }
    if not path.is_file():
        return checks
    raw = path.read_bytes()
    if not raw or len(raw) % 512:
        return checks
    application_start = parse_numeric_id(manifest.get("applicationStartAddress"))
    maximum_bytes = manifest.get("dualBankApplicationMaxBytes")
    if application_start is None or not isinstance(maximum_bytes, int):
        return checks
    allowed_end = application_start + maximum_bytes
    blocks: list[tuple[int, int, int, int, int]] = []
    for offset in range(0, len(raw), 512):
        block = raw[offset : offset + 512]
        magic0, magic1, flags, address, size, number, total, family = struct.unpack_from(
            "<IIIIIIII", block, 0
        )
        magic_end = struct.unpack_from("<I", block, 508)[0]
        if (magic0, magic1, magic_end) != (0x0A324655, 0x9E5D5157, 0x0AB16F30):
            return checks
        if size <= 0 or size > 476:
            return checks
        blocks.append((address, address + size, number, total, family))
    expected_total = len(blocks)
    structure_valid = (
        {number for _, _, number, _, _ in blocks} == set(range(expected_total))
        and {total for _, _, _, total, _ in blocks} == {expected_total}
        and {family for _, _, _, _, family in blocks} == {0xADA52840}
    )
    checks["application_uf2_structure_valid"] = structure_valid
    checks["application_uf2_preserves_bootloader"] = structure_valid and all(
        application_start <= start < end <= allowed_end for start, end, *_ in blocks
    )
    return checks


def read_dfu_package(path: Path) -> tuple[dict, dict, bytes, bytes]:
    return read_dfu_image(path, "application")


def read_dfu_image(path: Path, image_type: str) -> tuple[dict, dict, bytes, bytes]:
    if not path.is_file():
        return {}, {}, b"", b""
    with zipfile.ZipFile(path) as archive:
        names = set(archive.namelist())
        manifest = json.loads(archive.read("manifest.json"))
        image = manifest.get("manifest", {}).get(image_type, {})
        bin_name = image.get("bin_file")
        dat_name = image.get("dat_file")
        bin_bytes = archive.read(bin_name) if bin_name in names else b""
        dat_bytes = archive.read(dat_name) if dat_name in names else b""
    return manifest, image, bin_bytes, dat_bytes


def bootloader_ota_artifact_checks(
    manifest: dict,
    artifact_dir: Path,
    public_key: Path,
) -> dict[str, bool]:
    artifact_name = manifest.get("otaBootloaderArtifact")
    code_name = manifest.get("bootloaderCodeArtifact")
    artifact = artifact_dir / artifact_name if isinstance(artifact_name, str) else None
    release_artifact = (
        ROOT / "bootloader" / "releases" / artifact_name
        if isinstance(artifact_name, str)
        else None
    )
    if (artifact is None or not artifact.is_file()) and release_artifact is not None:
        artifact = release_artifact
    code_artifact = artifact_dir / code_name if isinstance(code_name, str) else None
    artifact_exists = artifact is not None and artifact.is_file()
    empty = {
        "ota_bootloader_artifact_exists": artifact_exists,
        "ota_bootloader_artifact_hash_matches_manifest": False,
        "ota_bootloader_package_has_only_bootloader": False,
        "ota_bootloader_payload_matches_candidate": False,
        "ota_bootloader_compiled_recovery_identities_present": False,
        "ota_bootloader_package_signature_valid": False,
        "ota_bootloader_package_softdevice_matches": False,
        "ota_bootloader_package_hardware_revision_matches": False,
    }
    if not artifact_exists:
        return empty

    package, image, bin_bytes, dat_bytes = read_dfu_image(artifact, "bootloader")
    package_manifest = package.get("manifest", {})
    init_packet = image.get("init_packet_data", {})
    declared_hash = manifest.get("otaBootloaderArtifactSha256")
    declared_bytes = manifest.get("otaBootloaderArtifactBytes")
    package_hash_matches = (
        hashlib.sha256(artifact.read_bytes()).hexdigest() == declared_hash
        and artifact.stat().st_size == declared_bytes
    )
    image_types = set(package_manifest) - {"dfu_version"}
    bootloader_only = image_types == {"bootloader"} and float(
        package_manifest.get("dfu_version", 0)
    ) >= 0.8
    payload_matches = (
        bool(bin_bytes)
        and len(bin_bytes) == manifest.get("bootloaderCodeArtifactBytes")
        and hashlib.sha256(bin_bytes).hexdigest()
        == manifest.get("bootloaderCodeArtifactSha256")
        and init_packet.get("firmware_length") == len(bin_bytes)
        and init_packet.get("firmware_hash") == hashlib.sha256(bin_bytes).hexdigest()
    )
    if code_artifact is not None and code_artifact.is_file():
        payload_matches = payload_matches and bin_bytes == code_artifact.read_bytes()
    compiled_recovery_identities_present = all(
        marker.encode("ascii") in bin_bytes
        for marker in (
            str(manifest.get("usbRecoveryVolumeLabel", "")),
            f'Door-Bootloader-ID: {manifest.get("usbRecoveryBuildId", "")}',
            str(manifest.get("dfuDeviceName", "")),
        )
        if marker
    ) and all(
        isinstance(manifest.get(field), str) and bool(manifest[field])
        for field in ("usbRecoveryVolumeLabel", "usbRecoveryBuildId", "dfuDeviceName")
    )
    signature_valid = bootloader_only and verify_signature(
        dat_bytes,
        init_packet.get("init_packet_ecds", ""),
        public_key,
    )
    softdevice_id = parse_numeric_id(manifest.get("softDeviceFirmwareId"))
    softdevice_matches = (
        softdevice_id is not None
        and softdevice_id in init_packet.get("softdevice_req", [])
        and init_packet.get("device_type") == 0x52
    )
    hardware_revision_matches = init_packet.get("device_revision") == 52840
    return {
        "ota_bootloader_artifact_exists": True,
        "ota_bootloader_artifact_hash_matches_manifest": package_hash_matches,
        "ota_bootloader_package_has_only_bootloader": bootloader_only,
        "ota_bootloader_payload_matches_candidate": payload_matches,
        "ota_bootloader_compiled_recovery_identities_present": compiled_recovery_identities_present,
        "ota_bootloader_package_signature_valid": signature_valid,
        "ota_bootloader_package_softdevice_matches": softdevice_matches,
        "ota_bootloader_package_hardware_revision_matches": hardware_revision_matches,
    }


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
        and manifest.get("maximumConnectionIntervalMs") == 15
        and manifest.get("dfuDeviceName") == "DoorDFUStable"
        and manifest.get("dataLengthExtension") is True
        and manifest.get("automaticTwoMegabitPhy") is True
        and manifest.get("flashWritePacing") is True
        and manifest.get("verifiedBlankBankEraseBypass") is True
        and manifest.get("backgroundInactiveBankPreparation") is False
    )


def candidate_fault_tolerance_profile_valid(manifest: dict) -> bool:
    """Require dual-bank transfer and automatic wireless recovery."""
    return (
        manifest.get("dualBankFirmware") is True
        and manifest.get("singleBankFallbackDisabled") is True
        and manifest.get("interruptedTransferRetainsBank0") is True
        and manifest.get("activationPowerLossRequiresPhysicalProof") is True
        and manifest.get("activationUsesUpstreamSettings") is True
        and manifest.get("interruptedActivationRecoversOverBle") is True
        and manifest.get("defaultToOtaDfu") is True
        and manifest.get("invalidAppDefaultsToOtaDfu") is True
        and manifest.get("doubleResetUsbRecoveryPreserved") is True
        and manifest.get("usbMassStorageRecoveryVolume") is True
        and manifest.get("usbRecoveryVolumeLabel") == "XIAO-SENSE"
        and manifest.get("usbRecoveryVolumeReadOnly") is True
        and manifest.get("usbCdcSignedRecovery") is True
        and manifest.get("applicationPackagesPreserveBootloader") is True
        and manifest.get("applicationFlashWriteProtection") == "ACL"
        and manifest.get("mbrWriteProtectedFromApplication") is True
        and manifest.get("bootloaderWriteProtectedFromApplication") is True
    )


def upstream_activation_contract_valid(
    manifest: dict, build_script: str, patcher: str
) -> bool:
    """Reject the custom activation path that caused a verified upload rollback."""
    combined = build_script + patcher
    forbidden = (
        "door_activation_stage",
        "door_activation_journal",
        "ACTIVATION_JOURNAL_ADDRESS",
        "StagingBankMaintenance",
    )
    return (
        manifest.get("activationUsesUpstreamSettings") is True
        and manifest.get("interruptedActivationRecoversOverBle") is True
        and not any(marker in combined for marker in forbidden)
        and "m_functions.activate = dfu_activate_app;" in build_script
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
