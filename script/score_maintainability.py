#!/usr/bin/env python3
"""Line-count maintainability gate for Door Unlocker Swift sources.

This gate follows SwiftLint's default metric thresholds as the external baseline:
file_length warns at 400 and errors at 1000; type_body_length warns at 250 and
errors at 350. The same limits apply to every source file and type.

The gate also blocks line-count gaming: code that crosses the file/type
thresholds should be split into smaller units, not compressed into very long
physical lines.
"""

from __future__ import annotations

import argparse
import json
import re
from dataclasses import asdict, dataclass
from pathlib import Path

from quality_test_support import swift_structure_text


ROOT = Path(__file__).resolve().parents[1]

SWIFT_ROOTS = (
    ROOT / "ios" / "DoorUnlockerApp",
    ROOT / "mac" / "DoorUnlockerAdmin" / "Sources",
    ROOT / "mac" / "DoorUnlockerAdmin" / "Tests",
    ROOT / "shared" / "DoorUnlockerShared" / "Sources",
    ROOT / "shared" / "DoorUnlockerShared" / "Tests",
)

FILE_WARNING_LINES = 400
FILE_ERROR_LINES = 1000
TYPE_WARNING_LINES = 250
TYPE_ERROR_LINES = 350
LINE_WARNING_CHARS = 160
LINE_ERROR_CHARS = 220

EXCLUDED_PATH_PARTS = {
    ".build",
    "DerivedData",
    ".swiftpm",
}


@dataclass(frozen=True)
class SwiftFileMetric:
    path: str
    lines: int
    warningLimit: int
    errorLimit: int

    @property
    def warning(self) -> bool:
        return self.lines > self.warningLimit

    @property
    def hard_violation(self) -> bool:
        return self.lines > self.errorLimit


@dataclass(frozen=True)
class SwiftTypeMetric:
    path: str
    name: str
    kind: str
    startLine: int
    lines: int
    warningLimit: int
    errorLimit: int

    @property
    def warning(self) -> bool:
        return self.lines > self.warningLimit

    @property
    def hard_violation(self) -> bool:
        return self.lines > self.errorLimit


@dataclass(frozen=True)
class SwiftLineMetric:
    path: str
    line: int
    chars: int
    warningLimit: int
    errorLimit: int
    preview: str

    @property
    def warning(self) -> bool:
        return self.chars > self.warningLimit

    @property
    def hard_violation(self) -> bool:
        return self.chars > self.errorLimit


def swift_paths() -> list[Path]:
    paths: list[Path] = []
    for root in SWIFT_ROOTS:
        if not root.exists():
            continue
        for path in root.rglob("*.swift"):
            rel_parts = set(path.relative_to(ROOT).parts)
            if rel_parts & EXCLUDED_PATH_PARTS:
                continue
            paths.append(path)
    return sorted(paths)


def rel(path: Path) -> str:
    return str(path.relative_to(ROOT))


def swift_file_metrics() -> list[SwiftFileMetric]:
    metrics: list[SwiftFileMetric] = []
    for path in swift_paths():
        relative_path = rel(path)
        text = path.read_text(encoding="utf-8")
        metrics.append(
            SwiftFileMetric(
                path=relative_path,
                lines=len(text.splitlines()),
                warningLimit=FILE_WARNING_LINES,
                errorLimit=FILE_ERROR_LINES,
            )
        )
    return metrics


TYPE_DECLARATION = re.compile(
    r"^\s*(?:@[A-Za-z0-9_().,:\s]+\s+)*"
    r"(?:(?:public|internal|private|fileprivate|open)\s+)?"
    r"(?:(?:final|indirect)\s+)?"
    r"(?P<kind>actor|class|enum|struct)\s+"
    r"(?P<name>[A-Za-z_][A-Za-z0-9_]*)"
)


def type_body_metrics() -> list[SwiftTypeMetric]:
    metrics: list[SwiftTypeMetric] = []
    for path in swift_paths():
        relative_path = rel(path)
        lines = swift_structure_text(path.read_text(encoding="utf-8")).splitlines()
        for index, line in enumerate(lines):
            match = TYPE_DECLARATION.match(line)
            if not match:
                continue

            depth = 0
            saw_opening_brace = False
            end_index = index
            for cursor in range(index, len(lines)):
                code = lines[cursor]
                if "{" in code:
                    saw_opening_brace = True
                if saw_opening_brace:
                    depth += code.count("{")
                    depth -= code.count("}")
                    if depth <= 0:
                        end_index = cursor
                        break

            if not saw_opening_brace:
                continue

            metrics.append(
                SwiftTypeMetric(
                    path=relative_path,
                    name=match.group("name"),
                    kind=match.group("kind"),
                    startLine=index + 1,
                    lines=end_index - index + 1,
                    warningLimit=TYPE_WARNING_LINES,
                    errorLimit=TYPE_ERROR_LINES,
                )
            )
    return metrics


def line_length_metrics() -> list[SwiftLineMetric]:
    metrics: list[SwiftLineMetric] = []
    for path in swift_paths():
        relative_path = rel(path)
        for index, line in enumerate(path.read_text(encoding="utf-8").splitlines()):
            chars = len(line)
            if chars <= LINE_WARNING_CHARS:
                continue
            metrics.append(
                SwiftLineMetric(
                    path=relative_path,
                    line=index + 1,
                    chars=chars,
                    warningLimit=LINE_WARNING_CHARS,
                    errorLimit=LINE_ERROR_CHARS,
                    preview=line.strip()[:140],
                )
            )
    return metrics


def clamp(value: float, lower: float = 0, upper: float = 100) -> float:
    return max(lower, min(upper, value))


def score(
    files: list[SwiftFileMetric],
    types: list[SwiftTypeMetric],
    lines: list[SwiftLineMetric],
) -> float:
    file_warnings = [metric for metric in files if metric.warning]
    type_warnings = [metric for metric in types if metric.warning]
    line_warnings = [metric for metric in lines if metric.warning]
    hard_violations = hard_gate_violations(files, types, lines)

    largest_file = max((metric.lines for metric in files), default=0)
    largest_type = max((metric.lines for metric in types), default=0)

    penalty = 0.0
    penalty += len(file_warnings) * 4.0
    penalty += len(type_warnings) * 3.0
    penalty += len(line_warnings) * 0.1
    penalty += len(hard_violations) * 18.0
    penalty += max(0, largest_file - FILE_WARNING_LINES) / 20
    penalty += max(0, largest_type - TYPE_WARNING_LINES) / 18

    return round(clamp(100 - penalty), 1)


def hard_gate_violations(
    files: list[SwiftFileMetric],
    types: list[SwiftTypeMetric],
    lines: list[SwiftLineMetric],
) -> list[dict[str, object]]:
    violations: list[dict[str, object]] = []
    for metric in files:
        if not metric.hard_violation:
            continue
        violations.append(
            {
                "kind": "file_length",
                "path": metric.path,
                "lines": metric.lines,
                "limit": metric.errorLimit,
                "reason": "file exceeds hard limit",
            }
        )

    for metric in types:
        if not metric.hard_violation:
            continue
        violations.append(
            {
                "kind": "type_body_length",
                "path": metric.path,
                "type": metric.name,
                "startLine": metric.startLine,
                "lines": metric.lines,
                "limit": metric.errorLimit,
                "reason": "type body exceeds hard limit",
            }
        )

    for metric in lines:
        if not metric.hard_violation:
            continue
        violations.append(
            {
                "kind": "line_length",
                "path": metric.path,
                "line": metric.line,
                "chars": metric.chars,
                "limit": metric.errorLimit,
                "reason": "line exceeds hard limit; split the code instead of compressing whitespace",
                "preview": metric.preview,
            }
        )

    return violations


def payload(threshold: float) -> dict[str, object]:
    files = swift_file_metrics()
    types = type_body_metrics()
    lines = line_length_metrics()
    hard_violations = hard_gate_violations(files, types, lines)
    maintainability_score = score(files, types, lines)
    warning_files = [metric for metric in files if metric.warning]
    warning_types = [metric for metric in types if metric.warning]
    warning_lines = [metric for metric in lines if metric.warning]

    return {
        "scoreKind": "project-maintainability-heuristic",
        "score": maintainability_score,
        "threshold": threshold,
        "passed": maintainability_score >= threshold and not hard_violations,
        "limits": {
            "fileWarningLines": FILE_WARNING_LINES,
            "fileErrorLines": FILE_ERROR_LINES,
            "typeWarningLines": TYPE_WARNING_LINES,
            "typeErrorLines": TYPE_ERROR_LINES,
            "lineWarningChars": LINE_WARNING_CHARS,
            "lineErrorChars": LINE_ERROR_CHARS,
        },
        "counts": {
            "swiftFiles": len(files),
            "swiftTypes": len(types),
            "warningFiles": len(warning_files),
            "warningTypes": len(warning_types),
            "warningLines": len(warning_lines),
            "hardViolations": len(hard_violations),
        },
        "hardViolations": hard_violations,
        "topFiles": [asdict(metric) for metric in sorted(files, key=lambda metric: metric.lines, reverse=True)[:12]],
        "topTypes": [asdict(metric) for metric in sorted(types, key=lambda metric: metric.lines, reverse=True)[:12]],
        "topLongLines": [asdict(metric) for metric in sorted(lines, key=lambda metric: metric.chars, reverse=True)[:12]],
        "limitations": [
            "Thresholds are SwiftLint-derived baselines; the numeric score is project-specific.",
            "File and type length indicate review pressure, not semantic correctness.",
            "Runtime correctness is established by the executable test and build steps.",
        ],
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--threshold", type=float, default=90.0)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    result = payload(args.threshold)
    if args.json:
        print(json.dumps(result, indent=2, sort_keys=True))
    else:
        print(f"Maintainability: {result['score']:.1f}/100")
        print(
            "  limits: "
            f"file warning={FILE_WARNING_LINES}, file error={FILE_ERROR_LINES}, "
            f"type warning={TYPE_WARNING_LINES}, type error={TYPE_ERROR_LINES}, "
            f"line warning={LINE_WARNING_CHARS}, line error={LINE_ERROR_CHARS}"
        )
        print(
            "  counts: "
            f"files={result['counts']['swiftFiles']}, types={result['counts']['swiftTypes']}, "
            f"warningFiles={result['counts']['warningFiles']}, "
            f"warningTypes={result['counts']['warningTypes']}, "
            f"warningLines={result['counts']['warningLines']}, "
            f"hardViolations={result['counts']['hardViolations']}"
        )
        print("  top files:")
        for metric in result["topFiles"][:8]:
            print(f"    {metric['lines']:5}  {metric['path']}")
        print("  top types:")
        for metric in result["topTypes"][:8]:
            print(f"    {metric['lines']:5}  {metric['path']}:{metric['startLine']} {metric['name']}")
        print("  top long lines:")
        for metric in result["topLongLines"][:8]:
            print(f"    {metric['chars']:5}  {metric['path']}:{metric['line']}")

        if result["hardViolations"]:
            print("  hard violations:")
            for violation in result["hardViolations"]:
                target = violation.get("type") or violation["path"]
                if violation["kind"] == "line_length":
                    print(
                        f"    - {violation['kind']}: {target}:{violation['line']} "
                        f"has {violation['chars']} chars, limit {violation['limit']}"
                    )
                else:
                    print(f"    - {violation['kind']}: {target} has {violation['lines']} lines, limit {violation['limit']}")
        print("  result: " + ("pass" if result["passed"] else f"below threshold {args.threshold:.1f} or hard violations present"))

    return 0 if result["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
