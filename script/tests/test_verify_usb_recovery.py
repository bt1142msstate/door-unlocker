import importlib.util
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[2]
MODULE_PATH = ROOT / "script/verify_usb_recovery.py"
SPEC = importlib.util.spec_from_file_location("verify_usb_recovery", MODULE_PATH)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class VerifyUsbRecoveryTests(unittest.TestCase):
    def test_extracts_identity_from_system_profiler_shape(self):
        candidates = MODULE.usb_identity_candidates(
            {
                "SPUSBDataType": [
                    {
                        "_name": "XIAO nRF52840 Sense",
                        "vendor_id": "Seeed (0x2886)",
                        "product_id": "0x8045",
                        "serial_num": "CONTROLLER-1",
                    }
                ]
            }
        )

        self.assertEqual(candidates[0]["serialNumber"], "CONTROLLER-1")

    def test_extracts_identity_from_ioreg_shape(self):
        candidates = MODULE.usb_identity_candidates(
            [
                {
                    "USB Product Name": "XIAO nRF52840 Sense",
                    "USB Serial Number": "CONTROLLER-2",
                    "idVendor": 0x2886,
                    "idProduct": 0x8045,
                }
            ]
        )

        self.assertEqual(candidates[0]["vendorId"], "0x2886")
        self.assertEqual(candidates[0]["serialNumber"], "CONTROLLER-2")


if __name__ == "__main__":
    unittest.main()
