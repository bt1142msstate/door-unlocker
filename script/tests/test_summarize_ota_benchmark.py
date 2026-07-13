import json
import tempfile
import unittest
from pathlib import Path

import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from summarize_ota_benchmark import aggregate_reports, report_upload_throughput_bps


class SummarizeOtaBenchmarkTests(unittest.TestCase):
    def report(self, path: Path, throughput: int) -> Path:
        path.write_text(
            json.dumps(
                {
                    "result": "pass",
                    "durationSeconds": 12,
                    "dfuTuningOverrides": {
                        "packetReceiptNotificationParameter": 9,
                        "dataObjectPreparationDelay": 0.3,
                    },
                    "timing": {
                        "progressSamples": [
                            {
                                "event": "progress",
                                "details": f"percent=100 currentBps=20000 avgBps={throughput}",
                            }
                        ]
                    },
                }
            ),
            encoding="utf-8",
        )
        return path

    def test_extracts_final_average_throughput(self):
        self.assertEqual(
            report_upload_throughput_bps(
                {
                    "timing": {
                        "progressSamples": [
                            {"details": "percent=90 currentBps=1 avgBps=18000"},
                            {"details": "percent=100 currentBps=2 avgBps=17500"},
                        ]
                    }
                }
            ),
            17500,
        )

    def test_requires_every_successful_run_to_clear_speed_gate(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            reports = [
                self.report(root / "fast.json", 18000),
                self.report(root / "slow.json", 16999),
            ]
            payload = aggregate_reports("run", "0.1.29", reports, 17000)
            case = payload["cases"][0]
            self.assertFalse(case["throughputGatePassed"])
            self.assertEqual(case["uploadThroughputBytesPerSecond"]["median"], 17499.5)

    def test_passes_only_when_all_runs_clear_threshold(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            reports = [
                self.report(root / "one.json", 17000),
                self.report(root / "two.json", 22000),
            ]
            payload = aggregate_reports("run", "0.1.29", reports, 17000)
            self.assertTrue(payload["cases"][0]["throughputGatePassed"])


if __name__ == "__main__":
    unittest.main()
