#!/usr/bin/env python3
"""Shared contract for physical iPhone cold/warm launch evidence."""

from __future__ import annotations

import hashlib
import math
import re
import statistics
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PROOF_PATH = ROOT / "docs/ios-launch-performance-last-run.json"
MINIMUM_SAMPLES = 10
COLD_MEDIAN_LIMIT_MS = 550
COLD_P95_LIMIT_MS = 800
WARM_MEDIAN_LIMIT_MS = 100
WARM_P95_LIMIT_MS = 150


def critical_path_files(root: Path = ROOT) -> list[Path]:
    explicit = [
        root / "ios/DoorUnlockerApp/project.yml",
        root / "ios/DoorUnlockerApp/DoorUnlocker.xcodeproj/project.pbxproj",
        root / "ios/DoorUnlockerApp/DoorUnlocker/Info.plist",
        root / "firmware/DoorUnlockerXiao/DoorUnlockerXiao.ino",
        root / "script/benchmark_ios_launch_gates.py",
        root / "script/ios_launch_performance_contract.py",
        root / "script/stress_mixed_clients.py",
    ]
    discovered = [
        *root.glob("ios/DoorUnlockerApp/DoorUnlocker/**/*.swift"),
        *root.glob("shared/DoorUnlockerShared/Sources/**/*.swift"),
    ]
    return sorted({path for path in explicit + discovered if path.is_file()})


def critical_path_sha256(root: Path = ROOT) -> str:
    digest = hashlib.sha256()
    for path in critical_path_files(root):
        relative = path.relative_to(root).as_posix().encode()
        digest.update(relative)
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


def app_version(root: Path = ROOT) -> str:
    source = (root / "ios/DoorUnlockerApp/project.yml").read_text(encoding="utf-8")
    match = re.search(r'MARKETING_VERSION:\s*"([^"]+)"', source)
    if not match:
        raise ValueError("MARKETING_VERSION not found")
    return match.group(1)


def firmware_version(root: Path = ROOT) -> str:
    source = (root / "firmware/DoorUnlockerXiao/DoorUnlockerXiao.ino").read_text(encoding="utf-8")
    match = re.search(r'CONTROLLER_FIRMWARE_VERSION\[\]\s*=\s*"([^"]+)"', source)
    if not match:
        raise ValueError("CONTROLLER_FIRMWARE_VERSION not found")
    return match.group(1)


def nearest_rank_percentile(values: list[int], fraction: float) -> int:
    ordered = sorted(values)
    return ordered[max(0, math.ceil(fraction * len(ordered)) - 1)]


def metrics(values: list[int]) -> dict[str, float | int]:
    return {
        "minimum": min(values),
        "median": round(statistics.median(values), 1),
        "mean": round(statistics.mean(values), 1),
        "p95": nearest_rank_percentile(values, 0.95),
        "maximum": max(values),
    }


def validate_proof(proof: dict, root: Path = ROOT) -> list[str]:
    failures: list[str] = []
    if proof.get("schemaVersion") != 1:
        failures.append("unsupported schemaVersion")
    if proof.get("passed") is not True:
        failures.append("physical launch benchmark did not pass")
    if proof.get("criticalPathSha256") != critical_path_sha256(root):
        failures.append("critical launch-path sources changed after the physical benchmark")
    if proof.get("appVersion") != app_version(root):
        failures.append("app version does not match the physical benchmark")
    if proof.get("firmwareVersion") != firmware_version(root):
        failures.append("firmware version does not match the physical benchmark")

    limits = {
        "cold": (COLD_MEDIAN_LIMIT_MS, COLD_P95_LIMIT_MS),
        "warm": (WARM_MEDIAN_LIMIT_MS, WARM_P95_LIMIT_MS),
    }
    for mode, (median_limit, p95_limit) in limits.items():
        section = proof.get(mode)
        if not isinstance(section, dict):
            failures.append(f"missing {mode} launch evidence")
            continue
        samples = section.get("samplesMs")
        if not isinstance(samples, list) or len(samples) < MINIMUM_SAMPLES or not all(
            isinstance(value, int) and value >= 0 for value in samples
        ):
            failures.append(f"{mode} launch requires at least {MINIMUM_SAMPLES} valid samples")
            continue
        measured = metrics(samples)
        if section.get("metrics") != measured:
            failures.append(f"{mode} launch metrics do not match samples")
        if measured["median"] > median_limit:
            failures.append(f"{mode} median {measured['median']}ms exceeds {median_limit}ms")
        if measured["p95"] > p95_limit:
            failures.append(f"{mode} p95 {measured['p95']}ms exceeds {p95_limit}ms")
    return failures
