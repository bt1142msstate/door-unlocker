import importlib.util
import hashlib
import json
import struct
import tempfile
import unittest
import zipfile
from pathlib import Path


ROOT = Path(__file__).parents[2]
MODULE_PATH = ROOT / "script/check_ota_bootloader_contract.py"
SPEC = importlib.util.spec_from_file_location("check_ota_bootloader_contract", MODULE_PATH)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
SIMULATOR_PATH = ROOT / "script/simulate_dual_bank_power_loss.py"
SIMULATOR_SPEC = importlib.util.spec_from_file_location(
    "simulate_dual_bank_power_loss", SIMULATOR_PATH
)
assert SIMULATOR_SPEC and SIMULATOR_SPEC.loader
SIMULATOR = importlib.util.module_from_spec(SIMULATOR_SPEC)
SIMULATOR_SPEC.loader.exec_module(SIMULATOR)


class OtaBootloaderContractTests(unittest.TestCase):
    def test_usb_recovery_proof_is_bound_to_hardware_reported_build_and_file_hash(self):
        with tempfile.TemporaryDirectory() as directory:
            proof_path = Path(directory) / "usb-proof.json"
            proof = {
                "passed": True,
                "observedBootloaderBuildId": "build-1",
                "expectedBootloaderBuildId": "build-1",
                "usbRecoveryBuildIdentityMatches": True,
                "usbRecoveryVolumeMounted": True,
                "usbRecoveryVolumeReadOnly": True,
                "usbRecoveryWriteRejected": True,
                "signedSerialRecoveryPassed": True,
                "pairingsAndSettingsPreserved": True,
                "packageImageTypes": ["application"],
            }
            proof_path.write_text(json.dumps(proof), encoding="utf-8")
            installed = {
                "usbRecoveryProofSha256": hashlib.sha256(proof_path.read_bytes()).hexdigest()
            }
            manifest = {"usbRecoveryBuildId": "build-1"}

            self.assertTrue(
                MODULE.usb_recovery_proof_matches(proof, installed, manifest, proof_path)
            )
            manifest["usbRecoveryBuildId"] = "build-2"
            self.assertFalse(
                MODULE.usb_recovery_proof_matches(proof, installed, manifest, proof_path)
            )

    @staticmethod
    def uf2_bytes(addresses, family=0xD663823C):
        blocks = []
        for number, address in enumerate(addresses):
            block = bytearray(512)
            struct.pack_into(
                "<IIIIIIII",
                block,
                0,
                0x0A324655,
                0x9E5D5157,
                0x2000,
                address,
                256,
                number,
                len(addresses),
                family,
            )
            struct.pack_into("<I", block, 508, 0x0AB16F30)
            blocks.append(block)
        return b"".join(blocks)

    @staticmethod
    def migration_manifest(raw, addresses):
        return {
            "applicationStartAddress": "0x27000",
            "bootloaderStartAddress": "0xF4000",
            "migrationArtifact": "candidate.uf2",
            "migrationArtifactSha256": hashlib.sha256(raw).hexdigest(),
            "migrationBlockCount": len(addresses),
            "migrationFamilyId": "0xD663823C",
            "migrationAddressRanges": [
                {
                    "start": f"0x{address:08X}",
                    "endExclusive": f"0x{address + 256:08X}",
                    "bytes": 256,
                }
                for address in addresses
            ],
        }

    def test_checked_in_package_signature_matches_public_key(self):
        package = ROOT / "ios/DoorUnlockerApp/DoorUnlocker/Firmware/DoorUnlockerXiao-signed-dfu.zip"
        with zipfile.ZipFile(package) as archive:
            manifest = json.loads(archive.read("manifest.json"))["manifest"]["application"]
            dat_bytes = archive.read(manifest["dat_file"])

        self.assertTrue(
            MODULE.verify_signature(
                dat_bytes,
                manifest["init_packet_data"]["init_packet_ecds"],
                ROOT / "docs/firmware-signing-public-key.pem",
            )
        )

    def test_verified_bootloader_ota_package_matches_exact_candidate(self):
        manifest = json.loads(
            (ROOT / "docs/firmware-signing-public-key.json").read_text(encoding="utf-8")
        )
        release = ROOT / "bootloader/releases" / manifest["otaBootloaderArtifact"]
        with tempfile.TemporaryDirectory() as directory:
            artifact_dir = Path(directory)
            staged_release = artifact_dir / release.name
            staged_release.write_bytes(release.read_bytes())
            with zipfile.ZipFile(release) as archive:
                package_manifest = json.loads(archive.read("manifest.json"))["manifest"]["bootloader"]
                code = archive.read(package_manifest["bin_file"])
            (artifact_dir / manifest["bootloaderCodeArtifact"]).write_bytes(code)
            checks = MODULE.bootloader_ota_artifact_checks(
                manifest,
                artifact_dir,
                ROOT / "docs/firmware-signing-public-key.pem",
            )

        self.assertTrue(all(checks.values()), checks)

    def test_checked_in_bootloader_release_self_verifies_without_dist_code(self):
        manifest = json.loads(
            (ROOT / "docs/firmware-signing-public-key.json").read_text(encoding="utf-8")
        )
        with tempfile.TemporaryDirectory() as directory:
            checks = MODULE.bootloader_ota_artifact_checks(
                manifest,
                Path(directory),
                ROOT / "docs/firmware-signing-public-key.pem",
            )

        self.assertTrue(all(checks.values()), checks)

    def test_signature_mutation_is_rejected(self):
        package = ROOT / "ios/DoorUnlockerApp/DoorUnlocker/Firmware/DoorUnlockerXiao-signed-dfu.zip"
        with zipfile.ZipFile(package) as archive:
            manifest = json.loads(archive.read("manifest.json"))["manifest"]["application"]
            dat_bytes = bytearray(archive.read(manifest["dat_file"]))
        dat_bytes[-1] ^= 1

        self.assertFalse(
            MODULE.verify_signature(
                bytes(dat_bytes),
                bytes(dat_bytes[-64:]).hex(),
                ROOT / "docs/firmware-signing-public-key.pem",
            )
        )

    def test_factory_and_signed_packages_wrap_the_same_application(self):
        firmware_dir = ROOT / "ios/DoorUnlockerApp/DoorUnlocker/Firmware"
        legacy = MODULE.read_dfu_package(firmware_dir / "DoorUnlockerXiao-dfu.zip")
        signed = MODULE.read_dfu_package(firmware_dir / "DoorUnlockerXiao-signed-dfu.zip")
        legacy_manifest, legacy_application, legacy_bin, legacy_dat = legacy
        signed_manifest, _, signed_bin, signed_dat = signed

        self.assertEqual(legacy_bin, signed_bin)
        self.assertLess(float(legacy_manifest["manifest"]["dfu_version"]), 0.8)
        self.assertIsInstance(legacy_application["init_packet_data"]["firmware_crc16"], int)
        self.assertLessEqual(len(legacy_dat), 32)
        self.assertGreaterEqual(float(signed_manifest["manifest"]["dfu_version"]), 0.8)
        self.assertGreater(len(signed_dat), 64)

    def test_application_release_packages_cannot_replace_the_bootloader(self):
        self.assertTrue(
            MODULE.application_package_only(
                {"application": {}, "dfu_version": 0.8}
            )
        )
        for image_type in ("bootloader", "softdevice", "softdevice_bootloader"):
            with self.subTest(image_type=image_type):
                self.assertFalse(
                    MODULE.application_package_only(
                        {
                            "application": {},
                            image_type: {},
                            "dfu_version": 0.8,
                        }
                    )
                )

    def test_application_uf2_is_restricted_to_application_bank(self):
        manifest = {
            "applicationStartAddress": "0x27000",
            "dualBankApplicationMaxBytes": 397312,
        }
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "application.uf2"
            path.write_bytes(self.uf2_bytes([0x27000, 0x27100], family=0xADA52840))
            checks = MODULE.application_uf2_artifact_checks(path, manifest)
            self.assertTrue(all(checks.values()), checks)

            path.write_bytes(self.uf2_bytes([0xF4000], family=0xADA52840))
            checks = MODULE.application_uf2_artifact_checks(path, manifest)
            self.assertTrue(checks["application_uf2_structure_valid"])
            self.assertFalse(checks["application_uf2_preserves_bootloader"])

    def test_der_encoding_handles_high_bit_and_leading_zero(self):
        raw = bytes.fromhex("80" + "00" * 31 + "00" * 31 + "01")
        encoded = MODULE.encode_der_signature(raw)
        self.assertEqual(encoded[0], 0x30)
        self.assertIn(b"\x02\x21\x00\x80", encoded)
        self.assertTrue(encoded.endswith(b"\x02\x01\x01"))

    def test_numeric_softdevice_ids_accept_hex_and_reject_invalid_values(self):
        self.assertEqual(MODULE.parse_numeric_id("0x0123"), 0x0123)
        self.assertEqual(MODULE.parse_numeric_id(291), 0x0123)
        self.assertIsNone(MODULE.parse_numeric_id("not-an-id"))

    def test_public_key_fingerprint_matches_checked_in_manifest(self):
        manifest = json.loads(
            (ROOT / "docs/firmware-signing-public-key.json").read_text(encoding="utf-8")
        )
        self.assertEqual(
            MODULE.public_key_id(ROOT / "docs/firmware-signing-public-key.pem"),
            manifest["publicKeyId"],
        )

    def test_bootloader_build_pins_compile_time_for_reproducible_bytes(self):
        source = (ROOT / "script/build_secure_bootloader.sh").read_text(encoding="utf-8")
        self.assertIn("SOURCE_DATE_EPOCH", source)
        self.assertIn("export SOURCE_DATE_EPOCH TZ=UTC LC_ALL=C", source)
        self.assertIn('"$BUILD_SCRIPT_SHA256"', source)
        self.assertIn('"$PATCHER_SHA256"', source)

    def test_reproducibility_proof_is_bound_to_every_bootloader_artifact(self):
        manifest = {
            "usbRecoveryBuildId": "build-id",
            "bootloaderUpstreamCommit": "commit",
            "sourceDateEpoch": 123,
            "buildScriptSha256": "script",
            "patcherSha256": "patcher",
            "artifactSha256": "hex",
            "migrationArtifactSha256": "uf2",
            "bootloaderCodeArtifactSha256": "code",
            "otaBootloaderArtifactSha256": "zip",
        }
        proof = {
            "passed": True,
            "usbRecoveryBuildId": "build-id",
            "bootloaderUpstreamCommit": "commit",
            "sourceDateEpoch": 123,
            "buildScriptSha256": "script",
            "patcherSha256": "patcher",
            "artifactHashes": {
                "artifact": "hex",
                "migrationArtifact": "uf2",
                "bootloaderCodeArtifact": "code",
                "otaBootloaderArtifact": "zip",
            },
        }
        self.assertTrue(MODULE.reproducibility_proof_matches(proof, manifest))
        proof["artifactHashes"]["otaBootloaderArtifact"] = "different"
        self.assertFalse(MODULE.reproducibility_proof_matches(proof, manifest))

    def test_fault_tolerance_profile_requires_application_write_protection(self):
        profile = {
            "dualBankFirmware": True,
            "singleBankFallbackDisabled": True,
            "interruptedTransferRetainsBank0": True,
            "activationPowerLossRequiresPhysicalProof": True,
            "activationUsesUpstreamSettings": True,
            "interruptedActivationRecoversOverBle": True,
            "defaultToOtaDfu": True,
            "invalidAppDefaultsToOtaDfu": True,
            "doubleResetUsbRecoveryPreserved": True,
            "usbMassStorageRecoveryVolume": True,
            "usbRecoveryVolumeLabel": "XIAO-SENSE",
            "usbRecoveryVolumeReadOnly": True,
            "usbCdcSignedRecovery": True,
            "applicationPackagesPreserveBootloader": True,
            "applicationFlashWriteProtection": "ACL",
            "mbrWriteProtectedFromApplication": True,
            "bootloaderWriteProtectedFromApplication": True,
        }
        self.assertTrue(MODULE.candidate_fault_tolerance_profile_valid(profile))
        profile["bootloaderWriteProtectedFromApplication"] = False
        self.assertFalse(MODULE.candidate_fault_tolerance_profile_valid(profile))

    def test_candidate_speed_profile_requires_every_optimized_transport_setting(self):
        profile = {
            "attMtuBytes": 247,
            "maxDfuPayloadBytes": 244,
            "gapEventLengthUnits": 12,
            "minimumConnectionIntervalMs": 15,
            "maximumConnectionIntervalMs": 15,
            "dfuDeviceName": "DoorDFUStable",
            "dataLengthExtension": True,
            "automaticTwoMegabitPhy": True,
            "flashWritePacing": True,
            "verifiedBlankBankEraseBypass": True,
            "backgroundInactiveBankPreparation": False,
        }
        self.assertTrue(MODULE.candidate_speed_profile_valid(profile))

        for key in profile:
            with self.subTest(key=key):
                mutated = dict(profile)
                mutated[key] = False if profile[key] is True else -1
                self.assertFalse(MODULE.candidate_speed_profile_valid(mutated))

    def test_candidate_fault_tolerance_requires_dual_bank_and_wireless_invalid_app_recovery(self):
        profile = {
            "dualBankFirmware": True,
            "singleBankFallbackDisabled": True,
            "interruptedTransferRetainsBank0": True,
            "activationPowerLossRequiresPhysicalProof": True,
            "activationUsesUpstreamSettings": True,
            "interruptedActivationRecoversOverBle": True,
            "defaultToOtaDfu": True,
            "invalidAppDefaultsToOtaDfu": True,
            "doubleResetUsbRecoveryPreserved": True,
            "usbMassStorageRecoveryVolume": True,
            "usbRecoveryVolumeLabel": "XIAO-SENSE",
            "usbRecoveryVolumeReadOnly": True,
            "usbCdcSignedRecovery": True,
            "applicationPackagesPreserveBootloader": True,
            "applicationFlashWriteProtection": "ACL",
            "mbrWriteProtectedFromApplication": True,
            "bootloaderWriteProtectedFromApplication": True,
        }
        self.assertTrue(MODULE.candidate_fault_tolerance_profile_valid(profile))

        for key in profile:
            with self.subTest(key=key):
                mutated = dict(profile)
                mutated[key] = False
                self.assertFalse(MODULE.candidate_fault_tolerance_profile_valid(mutated))

    def test_custom_activation_path_is_rejected(self):
        manifest = json.loads(
            (ROOT / "docs/firmware-signing-public-key.json").read_text(encoding="utf-8")
        )
        manifest["activationUsesUpstreamSettings"] = True
        manifest["interruptedActivationRecoversOverBle"] = True
        build_script = 'require_source_marker "$SOURCE" "m_functions.activate = dfu_activate_app;"'
        self.assertTrue(
            MODULE.upstream_activation_contract_valid(manifest, build_script, "")
        )
        self.assertFalse(
            MODULE.upstream_activation_contract_valid(
                manifest, build_script, "door_activation_journal"
            )
        )

    def test_required_fault_cases_must_all_be_named_and_passed(self):
        required = {"erase", "upload-30"}
        self.assertTrue(
            MODULE.required_cases_passed(
                [
                    {"phase": "erase", "passed": True, "report": "README.md"},
                    {"phase": "upload-30", "passed": True, "report": "README.md"},
                    {"phase": "extra", "passed": True, "report": "README.md"},
                ],
                required,
            )
        )
        self.assertFalse(
            MODULE.required_cases_passed(
                [
                    {"phase": "erase", "passed": True, "report": "README.md"},
                    {"phase": "upload-30", "passed": False, "report": "README.md"},
                ],
                required,
            )
        )

    def test_dual_bank_simulation_keeps_previous_firmware_at_every_transfer_cut(self):
        manifest = {
            "dualBankApplicationMaxBytes": 397312,
            "singleBankFallbackDisabled": True,
            "activationUsesUpstreamSettings": True,
            "interruptedActivationRecoversOverBle": True,
            "invalidAppDefaultsToOtaDfu": True,
        }
        report = SIMULATOR.simulate(manifest, 134452)
        self.assertTrue(report["passed"])
        self.assertEqual(len(report["powerCutCases"]), 100)
        self.assertTrue(report["allPreActivationCasesBootPreviousFirmware"])
        self.assertTrue(report["activationCopyRequiresPhysicalProof"])
        self.assertTrue(report["allActivationCasesRecoverOverBle"])
        self.assertGreater(report["activationCutPointsModeled"], 30_000)

    def test_dual_bank_simulation_rejects_oversized_image(self):
        manifest = {
            "dualBankApplicationMaxBytes": 397312,
            "singleBankFallbackDisabled": True,
            "activationUsesUpstreamSettings": True,
            "interruptedActivationRecoversOverBle": True,
            "invalidAppDefaultsToOtaDfu": True,
        }
        report = SIMULATOR.simulate(manifest, 397313)
        self.assertFalse(report["passed"])
        self.assertFalse(report["payloadFits"])

    def test_migration_artifact_accepts_only_expected_flash_regions(self):
        addresses = [0x00000000, 0x000F4000, 0x000FD800, 0x10001000]
        raw = self.uf2_bytes(addresses)
        manifest = self.migration_manifest(raw, addresses)
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, "candidate.uf2").write_bytes(raw)
            checks = MODULE.migration_artifact_checks(manifest, Path(directory))

        self.assertTrue(all(checks.values()))

    def test_migration_artifact_rejects_runtime_application_or_data_write(self):
        addresses = [0x00000000, 0x00027000, 0x000F4000, 0x000FD800, 0x10001000]
        raw = self.uf2_bytes(addresses)
        manifest = self.migration_manifest(raw, addresses)
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, "candidate.uf2").write_bytes(raw)
            checks = MODULE.migration_artifact_checks(manifest, Path(directory))

        self.assertTrue(checks["migration_uf2_block_map_matches_manifest"])
        self.assertFalse(checks["migration_uf2_preserves_runtime_flash"])

    def test_migration_artifact_rejects_corrupt_uf2_structure(self):
        addresses = [0x00000000, 0x000F4000, 0x000FD800, 0x10001000]
        raw = bytearray(self.uf2_bytes(addresses))
        raw[0] ^= 1
        manifest = self.migration_manifest(bytes(raw), addresses)
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, "candidate.uf2").write_bytes(raw)
            checks = MODULE.migration_artifact_checks(manifest, Path(directory))

        self.assertFalse(checks["migration_uf2_structure_valid"])
        self.assertFalse(checks["migration_uf2_preserves_runtime_flash"])


if __name__ == "__main__":
    unittest.main()
