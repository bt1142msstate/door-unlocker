import unittest
from pathlib import Path


ROOT = Path(__file__).parents[2]


class FirmwareReleaseWorkflowTests(unittest.TestCase):
    def test_every_version_tag_requires_exact_ota_and_usb_recovery_proof(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        tagged_job = workflow.split("  tagged-firmware-recovery-proof:\n", 1)[1].split(
            "  production-firmware-proof:\n", 1
        )[0]

        self.assertIn("if: startsWith(github.ref, 'refs/tags/v')", tagged_job)
        self.assertIn("check_ota_bootloader_contract.py --require-installed-recovery", tagged_job)
        self.assertIn("check_firmware_release_proof.py", tagged_job)
        self.assertNotIn("contains(github.ref_name, '-')", tagged_job)

    def test_stable_tags_keep_the_complete_physical_campaign_gate(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        production_job = workflow.split("  production-firmware-proof:\n", 1)[1]

        self.assertIn("!contains(github.ref_name, '-')", production_job)
        self.assertIn("check_ota_bootloader_contract.py --require-production", production_job)
        self.assertIn("check_ota_promotion_proof.py", production_job)


if __name__ == "__main__":
    unittest.main()
