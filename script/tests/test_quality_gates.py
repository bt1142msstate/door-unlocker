from __future__ import annotations

import datetime
import json
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parents[1]
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import check_fast_command_contract as fast_contract
import check_firmware_release_proof as firmware_release
import quality_test_support
import quality_suite
import score_maintainability
import score_shared_parity


class SwiftTestDiscoveryTests(unittest.TestCase):
    def test_counts_real_xctest_and_swift_testing_declarations_only(self) -> None:
        source = '''
        // func testCommentOnly() {}
        /*
        func testBlockCommentOnly() {}
        @Test func fakeSwiftTest() {}
        */
        let text = "func testInsideAString()"
        func testRealXCTest() {}
        @Test
        func realSwiftTest() {}
        '''

        self.assertEqual(quality_test_support.count_swift_test_declarations(source), 2)

    def test_nested_block_comments_do_not_inflate_count(self) -> None:
        source = "/* outer /* func testNested() {} */ still outer */\nfunc testActual() {}"
        self.assertEqual(quality_test_support.count_swift_test_declarations(source), 1)

    def test_multiline_strings_do_not_inflate_test_or_brace_counts(self) -> None:
        source = '''
        let fixture = """
        func testNotADeclaration() { } }
        """
        struct RealType { }
        '''
        structured = quality_test_support.swift_structure_text(source)
        self.assertEqual(quality_test_support.count_swift_test_declarations(source), 0)
        self.assertEqual(structured.count("{"), 1)
        self.assertEqual(structured.count("}"), 1)


class SharedParityGateTests(unittest.TestCase):
    def test_setting_confirmation_contract_is_registered(self) -> None:
        contract = next(
            contract
            for contract in score_shared_parity.CONTRACTS
            if contract.name == "setting-confirmation-lifecycle"
        )
        score, _ = score_shared_parity.contract_score(contract)
        self.assertEqual(score, 100)

    def test_contract_fails_when_platform_adapter_reference_is_missing(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            shared = root / "Policy.swift"
            tests = root / "PolicyTests.swift"
            ios = root / "IOSAdapter.swift"
            mac = root / "MacAdapter.swift"
            shared.write_text("enum SharedPolicy {}\n", encoding="utf-8")
            tests.write_text("func testPolicy() {}\n", encoding="utf-8")
            ios.write_text("SharedPolicy\n", encoding="utf-8")
            mac.write_text("// missing shared use\n", encoding="utf-8")

            contract = score_shared_parity.Contract(
                name="fixture",
                weight=1,
                shared_files=(shared,),
                test_files=(tests,),
                minimum_test_count=1,
                ios_uses=(score_shared_parity.SourceUse(ios, ("SharedPolicy",)),),
                mac_uses=(score_shared_parity.SourceUse(mac, ("SharedPolicy",)),),
            )

            score, details = score_shared_parity.contract_score(contract)
            self.assertLess(score, 100)
            self.assertFalse(next(item for item in details if item["name"] == "Mac uses shared contract")["passed"])

    def test_test_comments_cannot_satisfy_minimum_coverage_registration(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "Tests.swift"
            path.write_text("// func testNotReal() {}\n", encoding="utf-8")
            self.assertEqual(score_shared_parity.count_tests((path,)), 0)

    def test_source_use_can_span_feature_directory(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "First.swift").write_text("SharedPolicy.first\n", encoding="utf-8")
            feature = root / "Feature"
            feature.mkdir()
            (feature / "Second.swift").write_text("SharedPolicy.second\n", encoding="utf-8")

            use = score_shared_parity.SourceUse(
                root,
                ("SharedPolicy.first", "SharedPolicy.second"),
            )
            self.assertTrue(score_shared_parity.required_source_use_passes(use))


class MaintainabilityGateTests(unittest.TestCase):
    def test_hard_file_and_line_limits_are_blocking(self) -> None:
        files = [
            score_maintainability.SwiftFileMetric(
                path="Feature.swift",
                lines=1001,
                warningLimit=400,
                errorLimit=1000,
            )
        ]
        lines = [
            score_maintainability.SwiftLineMetric(
                path="Feature.swift",
                line=1,
                chars=221,
                warningLimit=160,
                errorLimit=220,
                preview="fixture",
            )
        ]

        violations = score_maintainability.hard_gate_violations(files, [], lines)
        self.assertEqual({violation["kind"] for violation in violations}, {"file_length", "line_length"})
        self.assertLess(score_maintainability.score(files, [], lines), 90)

    def test_file_hard_limit_has_no_exemptions(self) -> None:
        metric = score_maintainability.SwiftFileMetric(
            path="Feature.swift",
            lines=1001,
            warningLimit=400,
            errorLimit=1000,
        )
        self.assertTrue(metric.hard_violation)


class FastCommandContractGateTests(unittest.TestCase):
    def test_nonce_channel_rejects_connection_state_pollution(self) -> None:
        valid = """
        bool issueV3NonceTo(uint16_t connHandle) {
          return notifyNonce(connHandle);
        }
        void retryMissingV3Nonces() {}
        """
        polluted = valid.replace("return notifyNonce(connHandle);", "buildConnectionsStatePayload();")

        self.assertTrue(fast_contract.nonce_channel_is_dedicated(valid))
        self.assertFalse(fast_contract.nonce_channel_is_dedicated(polluted))

    def test_required_and_forbidden_markers_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "Source.swift"
            path.write_text("expected forbidden\n", encoding="utf-8")
            failures: list[str] = []
            fast_contract.require(path, ["expected", "missing"], failures)
            fast_contract.forbid(path, ["forbidden"], failures)
            self.assertEqual(len(failures), 2)

    def test_dfu_comparison_ignores_zip_timestamps_but_not_payload_drift(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            first = Path(directory) / "first.zip"
            second = Path(directory) / "second.zip"
            for path, timestamp, payload in (
                (first, (2026, 1, 1, 0, 0, 0), b"firmware"),
                (second, (2026, 7, 10, 1, 2, 4), b"firmware"),
            ):
                info = zipfile.ZipInfo("application.bin", date_time=timestamp)
                with zipfile.ZipFile(path, "w") as archive:
                    archive.writestr(info, payload)

            self.assertNotEqual(fast_contract.sha256(first), fast_contract.sha256(second))
            self.assertTrue(fast_contract.dfu_packages_match(first, second))

            with zipfile.ZipFile(second, "w") as archive:
                archive.writestr("application.bin", b"changed")
            self.assertFalse(fast_contract.dfu_packages_match(first, second))


class FirmwareReleaseProofGateTests(unittest.TestCase):
    def test_requires_ble_entry_and_matching_artifact(self) -> None:
        valid = {
            "result": "pass",
            "targetFirmware": "0.1.9",
            "verifiedOver": "ble",
            "entryCommandOver": "ble",
            "usbRecoveryCommandUsed": False,
            "package": {"payloadSha256": "abc"},
        }
        self.assertEqual(firmware_release.validate_release_proof(valid, "0.1.9", "abc"), [])

        invalid = dict(valid)
        invalid["entryCommandOver"] = "usb-c"
        self.assertTrue(firmware_release.validate_release_proof(invalid, "0.1.9", "abc"))


class QualityReportAccuracyTests(unittest.TestCase):
    def test_public_report_redacts_local_repository_and_home_paths(self) -> None:
        step = quality_suite.SuiteStep(
            name="Fixture",
            command=[str(quality_suite.ROOT / "script/check.py")],
            status="pass",
            durationSeconds=0.1,
            exitCode=0,
            summary=str(quality_suite.ROOT / "artifact.zip"),
            warningCount=1,
            warnings=[str(Path.home() / "Library/tool.py")],
        )
        payload = quality_suite.public_step_payload(step)
        serialized = json.dumps(payload)

        self.assertNotIn(str(quality_suite.ROOT), serialized)
        self.assertNotIn(str(Path.home()), serialized)
        self.assertEqual(payload["summary"], "./artifact.zip")

    def test_fast_run_cannot_claim_full_or_platform_parity(self) -> None:
        class Arguments:
            fast = True
            maintainability_threshold = 90
            modularity_threshold = 95
            shared_parity_threshold = 95
            live_mac_ui = False
            install_mac = False
            install_ios = False
            no_launch_ios = False
            live_mixed_client = False

        step = quality_suite.SuiteStep(
            name="Shared package independent tests",
            command=["swift", "test"],
            status="pass",
            durationSeconds=0.1,
            exitCode=0,
            summary="pass",
        )
        with tempfile.TemporaryDirectory() as directory:
            report = Path(directory) / "report.json"
            quality_suite.write_report(report, [step], 0.1, Arguments())
            payload = __import__("json").loads(report.read_text(encoding="utf-8"))

        self.assertTrue(payload["passed"])
        self.assertFalse(payload["fullSuitePassed"])
        self.assertFalse(payload["claims"]["platformAdapterVectorsVerified"])
        self.assertFalse(payload["claims"]["endToEndCrossPlatformBluetoothParityVerified"])

    def test_live_mixed_client_evidence_must_be_current_complete_and_cross_platform(self) -> None:
        not_before = datetime.datetime(2026, 7, 11, tzinfo=datetime.timezone.utc)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "evidence.json"
            valid = {
                "generatedAt": "2026-07-11T00:00:01+00:00",
                "passed": True,
                "commandCount": 4,
                "crossSubscriberConfirmationCount": 4,
                "simultaneousSubscribersVerified": True,
                "commands": [
                    {"origin": "iphone", "requestToConfirmationMs": 10},
                    {"origin": "mac", "requestToConfirmationMs": 11},
                    {"origin": "iphone", "requestToConfirmationMs": 12},
                    {"origin": "mac", "requestToConfirmationMs": 13},
                ],
            }
            path.write_text(json.dumps(valid), encoding="utf-8")
            self.assertEqual(
                quality_suite.validate_live_mixed_client_report(
                    path,
                    collection_key="commands",
                    count_key="commandCount",
                    minimum_count=4,
                    not_before=not_before,
                ),
                [],
            )

            valid["generatedAt"] = "2026-07-10T23:59:59+00:00"
            valid["commands"] = valid["commands"][:3]
            path.write_text(json.dumps(valid), encoding="utf-8")
            failures = quality_suite.validate_live_mixed_client_report(
                path,
                collection_key="commands",
                count_key="commandCount",
                minimum_count=4,
                not_before=not_before,
            )
            self.assertTrue(any("not from this suite run" in failure for failure in failures))
            self.assertTrue(any("requires at least 4" in failure for failure in failures))
            self.assertTrue(any("does not match" in failure for failure in failures))

    def test_live_mixed_client_steps_are_opt_in(self) -> None:
        class Arguments:
            fast = True
            maintainability_threshold = 90
            modularity_threshold = 95
            shared_parity_threshold = 95
            live_mac_ui = False
            live_mixed_client = True
            install_mac = False
            install_ios = False
            no_launch_ios = False
            firmware_release = False

        names = [name for name, _ in quality_suite.base_steps(Arguments())]
        self.assertIn("Live mixed-client command stress", names)
        self.assertIn("Live mixed-client settings stress", names)


if __name__ == "__main__":
    unittest.main()
