import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[2]
HELPER = ROOT / "script/physical_handoff.sh"
VERIFIER = ROOT / "script/verify_ios_ota.sh"
FLASHER = ROOT / "script/flash_xiao_uf2.sh"
BOOTLOADER_INSTALLER = ROOT / "script/install_secure_bootloader.sh"


class PhysicalHandoffTests(unittest.TestCase):
    def test_dry_run_preserves_requested_handoff_contract(self):
        result = subprocess.run(
            [
                str(HELPER),
                "--dry-run",
                "--mode",
                "gui",
                "--title",
                "Power test",
                "--instruction",
                "Prepare the battery.",
                "--countdown",
                "3",
                "--confirmation",
                "Reconnect it.",
                "--confirm-label",
                "Power restored",
            ],
            cwd=ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("mode=gui", result.stdout)
        self.assertIn("countdown=3", result.stdout)
        self.assertIn("confirm_label=Power restored", result.stdout)

    def test_named_presets_cover_required_physical_flows(self):
        expected_labels = {
            "power-cycle-battery": "Power restored",
            "connect-usb": "USB-C connected",
            "return-to-battery": "Running on battery",
            "reset-once": "Reset pressed",
            "reset-twice": "Pressed twice",
        }
        for preset, label in expected_labels.items():
            with self.subTest(preset=preset):
                result = subprocess.run(
                    [str(HELPER), "--dry-run", "--preset", preset],
                    cwd=ROOT,
                    capture_output=True,
                    text=True,
                    check=False,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(f"preset={preset}", result.stdout)
                self.assertIn(f"confirm_label={label}", result.stdout)

    def test_invalid_countdown_is_rejected(self):
        result = subprocess.run(
            [str(HELPER), "--dry-run", "--countdown", "11"],
            cwd=ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 2)

    def test_power_loss_verifier_uses_blocking_handoff_helper(self):
        source = VERIFIER.read_text(encoding="utf-8")
        self.assertIn('"$ROOT_DIR/script/physical_handoff.sh"', source)
        self.assertIn('--preset "power-cycle-battery"', source)
        self.assertIn('--preset "return-to-battery"', source)
        self.assertIn("require_safe_power_loss_testbed", source)
        self.assertIn('"dualBankFirmware": True', source)
        self.assertIn('proof.get("swdRecoveryAvailable") is not True', source)
        self.assertIn("--accept-no-swd-recovery-risk", source)
        self.assertNotIn('say "Prepare to disconnect', source)

    def test_factory_bootloader_cannot_start_physical_power_loss_test(self):
        result = subprocess.run(
            [str(VERIFIER), "--device-udid", "not-needed-for-safety-gate"],
            cwd=ROOT,
            env={
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "INTERRUPT_MODE": "controller-power-loss",
                "INTERRUPT_AT_PROGRESS": "30",
                "BOOTLOADER_INSTALLED_PROOF_PATH": str(
                    ROOT / "docs/does-not-exist-installed-proof.json"
                ),
            },
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("Refusing physical controller power-loss test", result.stderr)
        self.assertIn("no installed proof", result.stderr)

    def test_recovery_scripts_use_reset_handoff_instead_of_console_prompt(self):
        for path in (FLASHER, BOOTLOADER_INSTALLER):
            with self.subTest(path=path.name):
                source = path.read_text(encoding="utf-8")
                self.assertIn("physical_handoff.sh", source)
                self.assertIn("--preset reset-twice", source)


if __name__ == "__main__":
    unittest.main()
