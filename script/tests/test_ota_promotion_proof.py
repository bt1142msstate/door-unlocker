import hashlib
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[2]
MODULE_PATH = ROOT / "script/check_ota_promotion_proof.py"
SPEC = importlib.util.spec_from_file_location("check_ota_promotion_proof", MODULE_PATH)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
SHA_A = "a" * 64
SHA_B = "b" * 64
SHA_C = "c" * 64


class OtaPromotionProofTests(unittest.TestCase):
    def valid_values(self, root: Path):
        manifest = {
            "bootloaderCodeArtifactSha256": "code",
            "otaBootloaderArtifactSha256": "ota",
            "dfuDeviceName": "DoorDFUStable",
            "usbRecoveryBuildId": "build-identity",
        }
        transitions = []
        for index, (start, target, payload_hash) in enumerate(
            (("0.1.30", "0.1.31", SHA_A), ("0.1.31", "0.1.32", SHA_B)),
            start=1,
        ):
            run_id = f"run-{index}"
            package_hash = SHA_C if index == 1 else "d" * 64
            evidence = {
                "result": "pass",
                "runId": run_id,
                "targetFirmware": target,
                "bootloaderName": "DoorDFUStable",
                "packageProfile": "signed-fast",
                "package": {
                    "sha256": package_hash,
                    "applicationPayloadSha256": payload_hash,
                },
            }
            path = root / f"evidence-{index}.json"
            path.write_text(json.dumps(evidence), encoding="utf-8")
            transitions.append(
                {
                    "passed": True,
                    "fromFirmware": start,
                    "toFirmware": target,
                    "verifiedOver": "ble",
                    "controllerUsbAttached": False,
                    "clientPlatform": "macos",
                    "bootloaderName": "DoorDFUStable",
                    "packageProfile": "signed-fast",
                    "signedPackageSha256": package_hash,
                    "applicationPayloadSha256": payload_hash,
                    "runId": run_id,
                    "startedAt": f"2026-07-13T11:0{index}:00Z",
                    "verifiedAt": f"2026-07-13T11:0{index}:30Z",
                    "stableVerifiedAt": f"2026-07-13T11:0{index}:45Z",
                    "evidencePath": str(path),
                    "evidenceSha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                }
            )
        proof = {**{k: manifest[k] for k in ("bootloaderCodeArtifactSha256", "otaBootloaderArtifactSha256")}, "passed": True, "transitions": transitions}
        usb = {
            "passed": True,
            "observedBootloaderBuildId": "build-identity",
            "packageImageTypes": ["application"],
            "signedPackageSha256": SHA_C,
            "applicationPayloadSha256": SHA_A,
            "baselineSha256": SHA_B,
            "usbDevice": {"serialNumber": "device-1"},
            "expectedFirmwareVersion": "0.1.32",
            "recoveredStatus": {"firmware_version": "0.1.32"},
            **{
                key: True
                for key in (
                    "usbRecoveryVolumeMounted",
                    "usbRecoveryBoardIdentityMatches",
                    "usbRecoveryBuildIdentityMatches",
                    "usbRecoveryVolumeReadOnly",
                    "usbRecoveryWriteRejected",
                    "uniqueUsbCdcSerialPresent",
                    "usbHardwareIdentityPresent",
                    "usbHardwareIdentityMatchesBaseline",
                    "signedSerialRecoveryPassed",
                    "pairingsAndSettingsPreserved",
                )
            },
        }
        return proof, usb, manifest

    def test_accepts_content_bound_wireless_transitions_and_usb_recovery(self):
        with tempfile.TemporaryDirectory() as directory:
            proof, usb, manifest = self.valid_values(Path(directory))
            self.assertEqual(MODULE.validate(proof, usb, manifest), [])

    def test_rejects_nonconsecutive_or_usb_assisted_transition(self):
        with tempfile.TemporaryDirectory() as directory:
            proof, usb, manifest = self.valid_values(Path(directory))
            proof["transitions"][1]["fromFirmware"] = "0.1.29"
            proof["transitions"][1]["controllerUsbAttached"] = True
            failures = MODULE.validate(proof, usb, manifest)
            self.assertIn("OTA transitions are not consecutive", failures)
            self.assertIn("transition 2 used USB during OTA proof", failures)

    def test_rejects_stale_or_incomplete_usb_proof(self):
        with tempfile.TemporaryDirectory() as directory:
            proof, usb, manifest = self.valid_values(Path(directory))
            usb["passed"] = False
            usb["usbRecoveryWriteRejected"] = False
            failures = MODULE.validate(proof, usb, manifest)
            self.assertIn("physical USB recovery exercise has not passed", failures)
            self.assertIn("USB proof lacks usbRecoveryWriteRejected", failures)

    def test_rejects_usb_proof_from_a_different_bootloader_build(self):
        with tempfile.TemporaryDirectory() as directory:
            proof, usb, manifest = self.valid_values(Path(directory))
            usb["observedBootloaderBuildId"] = "older-build"
            failures = MODULE.validate(proof, usb, manifest)
            self.assertIn(
                "USB proof is not bound to the hardware-reported bootloader build ID",
                failures,
            )

    def test_rejects_early_or_reused_transition_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            proof, usb, manifest = self.valid_values(Path(directory))
            proof["transitions"][0]["stableVerifiedAt"] = proof["transitions"][0]["verifiedAt"]
            proof["transitions"][1]["applicationPayloadSha256"] = proof["transitions"][0]["applicationPayloadSha256"]
            failures = MODULE.validate(proof, usb, manifest)
            self.assertIn("transition 1 lacks the 15-second stable post-reboot recheck", failures)
            self.assertIn("OTA transitions did not exercise distinct firmware payloads", failures)


if __name__ == "__main__":
    unittest.main()
