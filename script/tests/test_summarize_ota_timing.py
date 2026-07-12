import importlib.util
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).parents[1] / "summarize_ota_timing.py"
SPEC = importlib.util.spec_from_file_location("summarize_ota_timing", MODULE_PATH)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class SummarizeOtaTimingTests(unittest.TestCase):
    def test_summarizes_structured_phases(self):
        report = MODULE.summarize(
            "\n".join(
                [
                    "DUStartup 440ms firmware_send_enter_ota_written",
                    "DUFirmware 0.000s scan_started packageBytes=135327",
                    "DUFirmware 0.750s bootloader_selected",
                    "DUFirmware 10.000s progress percent=10 currentBps=1600 avgBps=1600",
                    "DoorFirmwareDFU[A] Upload completed in 82.68 seconds",
                    "DUFirmware 84.100s completed upload=83.3s",
                    "DUStartup 93342ms firmware_pending_cleared 0.1.26->0.1.26",
                ]
            )
        )

        self.assertEqual(report["endToEndSeconds"], 92.902)
        self.assertEqual(report["bootloaderDiscoverySeconds"], 0.75)
        self.assertEqual(report["uploadSeconds"], 82.68)
        self.assertEqual(report["postUploadVerificationSeconds"], 9.472)
        self.assertEqual(report["managerTotalSeconds"], 84.1)
        self.assertEqual(len(report["progressSamples"]), 1)

    def test_missing_markers_remain_unknown(self):
        report = MODULE.summarize("unrelated output")
        self.assertIsNone(report["endToEndSeconds"])
        self.assertIsNone(report["uploadSeconds"])
        self.assertEqual(report["events"], [])


if __name__ == "__main__":
    unittest.main()
