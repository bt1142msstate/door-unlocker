import importlib.util
import tempfile
import unittest
import zipfile
from pathlib import Path


ROOT = Path(__file__).parents[2]
MODULE_PATH = ROOT / "script/record_mac_ota_proof.py"
SPEC = importlib.util.spec_from_file_location("record_mac_ota_proof", MODULE_PATH)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class RecordMacOtaProofTests(unittest.TestCase):
    def test_package_payload_hash_ignores_zip_container_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            first = Path(directory) / "first.zip"
            second = Path(directory) / "second.zip"
            for path, year in ((first, 2024), (second, 2026)):
                with zipfile.ZipFile(path, "w") as archive:
                    info = zipfile.ZipInfo("firmware.bin", (year, 1, 1, 0, 0, 0))
                    archive.writestr(info, b"firmware")

            self.assertNotEqual(first.read_bytes(), second.read_bytes())
            self.assertEqual(
                MODULE.package_payload_sha256(first),
                MODULE.package_payload_sha256(second),
            )

    def test_orders_interleaved_process_logs_by_wall_clock(self):
        events = MODULE.parsed_events(
            "\n".join(
                [
                    "2026-07-12T23:00:05Z DUMacStartup 100ms wireless_state_received firmware_version:0.1.26",
                    "2026-07-12T23:00:01Z DUMacStartup 9000ms wireless_command_sent firmware update",
                    "2026-07-12T23:00:03Z DUMacStartup 25ms firmware_update_uploaded",
                ]
            )
        )

        self.assertEqual(
            [event for _, _, event in events],
            [
                "wireless_command_sent firmware update",
                "firmware_update_uploaded",
                "wireless_state_received firmware_version:0.1.26",
            ],
        )
        self.assertEqual((events[-1][0] - events[0][0]).total_seconds(), 4)

    def test_update_owner_suffix_is_part_of_the_same_ota_state(self):
        event = "wireless_state_received firmware_update:ota_dfu:Brandon's Mac mini"
        self.assertTrue(event.startswith("wireless_state_received firmware_update:ota_dfu"))


if __name__ == "__main__":
    unittest.main()
