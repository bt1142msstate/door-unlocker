#!/usr/bin/env python3
"""Aggregate Door Unlocker OTA benchmark reports."""

from __future__ import annotations

import argparse
import json
import statistics
from pathlib import Path


def load_report(path: Path) -> dict[str, object]:
    if not path.exists():
        return {"path": str(path), "result": "missing"}

    payload = json.loads(path.read_text(encoding="utf-8"))
    payload["path"] = str(path)
    return payload


def report_case_key(report: dict[str, object]) -> tuple[object, object]:
    overrides = report.get("dfuTuningOverrides")
    if not isinstance(overrides, dict):
        overrides = {}
    return (
        overrides.get("packetReceiptNotificationParameter"),
        overrides.get("dataObjectPreparationDelay"),
    )


def summarize_case(prn: object, delay: object, reports: list[dict[str, object]]) -> dict[str, object]:
    passed = [item for item in reports if item.get("result") == "pass"]
    durations = [item["durationSeconds"] for item in passed if isinstance(item.get("durationSeconds"), int)]
    return {
        "packetReceiptNotificationParameter": prn,
        "dataObjectPreparationDelay": delay,
        "attempts": len(reports),
        "passes": len(passed),
        "failures": len(reports) - len(passed),
        "durationSeconds": {
            "min": min(durations) if durations else None,
            "median": statistics.median(durations) if durations else None,
            "max": max(durations) if durations else None,
        },
    }


def aggregate_reports(run_id: str, target_firmware: str, report_paths: list[Path]) -> dict[str, object]:
    reports = [load_report(path) for path in report_paths]
    cases: dict[tuple[object, object], list[dict[str, object]]] = {}
    for report in reports:
        cases.setdefault(report_case_key(report), []).append(report)

    case_summaries = [
        summarize_case(prn, delay, case_reports)
        for (prn, delay), case_reports in sorted(cases.items(), key=lambda item: (str(item[0][0]), str(item[0][1])))
    ]
    return {
        "runId": run_id,
        "targetFirmware": target_firmware,
        "reports": reports,
        "cases": case_summaries,
    }


def write_summary(payload: dict[str, object], output_dir: Path, latest_path: Path | None) -> Path:
    output_dir.mkdir(parents=True, exist_ok=True)
    aggregate_path = output_dir / "summary.json"
    serialized = json.dumps(payload, indent=2, sort_keys=True) + "\n"
    aggregate_path.write_text(serialized, encoding="utf-8")
    if latest_path is not None:
        latest_path.parent.mkdir(parents=True, exist_ok=True)
        latest_path.write_text(serialized, encoding="utf-8")
    return aggregate_path


def print_summary(aggregate_path: Path, latest_path: Path | None, payload: dict[str, object]) -> None:
    print(f"Benchmark summary: {aggregate_path}")
    if latest_path is not None:
        print(f"Latest summary: {latest_path}")

    cases = payload.get("cases") if isinstance(payload, dict) else []
    if not isinstance(cases, list):
        return
    for summary in cases:
        if not isinstance(summary, dict):
            continue
        durations = summary.get("durationSeconds")
        median = durations.get("median") if isinstance(durations, dict) else None
        print(
            "PRN={prn} objectDelay={delay}: passes={passes}/{attempts}, median={median}s".format(
                prn=summary.get("packetReceiptNotificationParameter"),
                delay=summary.get("dataObjectPreparationDelay"),
                passes=summary.get("passes"),
                attempts=summary.get("attempts"),
                median=median,
            )
        )


def main() -> int:
    parser = argparse.ArgumentParser(description="Aggregate OTA benchmark report JSON files.")
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--target", required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--latest", type=Path)
    parser.add_argument("reports", nargs="+", type=Path)
    args = parser.parse_args()

    payload = aggregate_reports(args.run_id, args.target, args.reports)
    aggregate_path = write_summary(payload, args.output_dir, args.latest)
    print_summary(aggregate_path, args.latest, payload)

    failures = 0
    for report in payload["reports"]:
        if isinstance(report, dict) and report.get("result") != "pass":
            failures += 1
    return min(failures, 255)


if __name__ == "__main__":
    raise SystemExit(main())
