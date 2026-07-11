from pathlib import Path
import sys
import unittest


SCRIPT_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPT_DIR))

from check_bench_wiring_paths import WirePath, issues_for_mode  # noqa: E402


class BenchWiringBridgeTests(unittest.TestCase):
    def setUp(self) -> None:
        self.horizontal = WirePath("positive servo", frozenset({"wire", "red"}), "M0 10 H20")
        self.vertical = WirePath("ground buck", frozenset({"wire", "ground"}), "M10 0 V20")

    def test_unmarked_crossing_fails(self) -> None:
        issues = issues_for_mode([self.horizontal, self.vertical], [], "buck")
        self.assertEqual(issues, ["wire crossing: 'positive servo' / 'ground buck' at (10, 10)"])

    def test_matching_bridge_allows_one_explicit_crossing(self) -> None:
        bridge = WirePath("positive servo", frozenset({"wire", "wire-bridge", "red"}), "M6 10 H14")
        self.assertEqual(issues_for_mode([self.horizontal, self.vertical], [bridge], "buck"), [])

    def test_unrelated_bridge_does_not_hide_crossing(self) -> None:
        bridge = WirePath("other wire", frozenset({"wire", "wire-bridge"}), "M6 10 H14")
        issues = issues_for_mode([self.horizontal, self.vertical], [bridge], "buck")
        self.assertEqual(len(issues), 1)


if __name__ == "__main__":
    unittest.main()
