import importlib.util
import struct
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).resolve().parents[1] / "build_signed_dfu_package.py"
SPEC = importlib.util.spec_from_file_location("build_signed_dfu_package", MODULE_PATH)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class SignedDfuPackageTests(unittest.TestCase):
    def test_bootloader_revision_is_encoded_in_legacy_init_header(self):
        packet = MODULE.build_init_packet(
            device_type=0x0052,
            device_revision=52840,
            softdevice_requests=[0x0123],
            payload_length=4096,
            payload_hash=bytes(range(32)),
        )

        device_type, device_revision, app_version, requirement_count = struct.unpack(
            "<HHIH", packet[:10]
        )
        self.assertEqual(device_type, 0x0052)
        self.assertEqual(device_revision, 52840)
        self.assertEqual(app_version, 0xFFFFFFFF)
        self.assertEqual(requirement_count, 1)


if __name__ == "__main__":
    unittest.main()
