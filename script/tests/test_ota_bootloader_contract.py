import importlib.util
import json
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


if __name__ == "__main__":
    unittest.main()
