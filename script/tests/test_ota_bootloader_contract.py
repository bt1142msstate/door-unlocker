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


class OtaBootloaderContractTests(unittest.TestCase):
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
        package = ROOT / "ios/DoorUnlockerApp/DoorUnlocker/Firmware/DoorUnlockerXiao-dfu.zip"
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

    def test_signature_mutation_is_rejected(self):
        package = ROOT / "ios/DoorUnlockerApp/DoorUnlocker/Firmware/DoorUnlockerXiao-dfu.zip"
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

    def test_candidate_speed_profile_requires_every_optimized_transport_setting(self):
        profile = {
            "attMtuBytes": 247,
            "maxDfuPayloadBytes": 244,
            "gapEventLengthUnits": 12,
            "minimumConnectionIntervalMs": 15,
            "maximumConnectionIntervalMs": 30,
            "dataLengthExtension": True,
            "automaticTwoMegabitPhy": True,
            "flashWritePacing": True,
        }
        self.assertTrue(MODULE.candidate_speed_profile_valid(profile))

        for key in profile:
            with self.subTest(key=key):
                mutated = dict(profile)
                mutated[key] = False if profile[key] is True else -1
                self.assertFalse(MODULE.candidate_speed_profile_valid(mutated))

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
