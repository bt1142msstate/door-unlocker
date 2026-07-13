#!/usr/bin/env python3
"""Build the recovery bootloader twice and require byte-identical artifacts."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
BUILD_SCRIPT = ROOT / "script/build_secure_bootloader.sh"
PUBLIC_MANIFEST = ROOT / "docs/firmware-signing-public-key.json"
DEFAULT_PROOF = ROOT / "docs/bootloader-reproducibility-proof.json"
ARTIFACT_FIELDS = {
    "artifact": "artifactSha256",
    "migrationArtifact": "migrationArtifactSha256",
    "bootloaderCodeArtifact": "bootloaderCodeArtifactSha256",
    "otaBootloaderArtifact": "otaBootloaderArtifactSha256",
}


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def build_once(base: Path, run: str) -> dict:
    output = base / run / "output"
    release = base / run / "release"
    manifest_path = base / run / "manifest.json"
    env = os.environ.copy()
    env.update(
        {
            "DOOR_BOOTLOADER_WORK_DIR": str(base / run / "work"),
            "DOOR_BOOTLOADER_OUTPUT_DIR": str(output),
            "DOOR_BOOTLOADER_RELEASE_DIR": str(release),
            "DOOR_BOOTLOADER_PUBLIC_MANIFEST": str(manifest_path),
        }
    )
    subprocess.run(
        [str(BUILD_SCRIPT)],
        cwd=ROOT,
        env=env,
        check=True,
        stdout=subprocess.DEVNULL,
    )
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    artifacts = {}
    for name_field, hash_field in ARTIFACT_FIELDS.items():
        path = output / manifest[name_field]
        artifacts[name_field] = {
            "name": path.name,
            "bytes": path.stat().st_size,
            "sha256": sha256(path),
            "declaredSha256": manifest[hash_field],
        }
    return {"manifest": manifest, "artifacts": artifacts}


def compare_runs(first: dict, second: dict, expected: dict) -> list[str]:
    failures: list[str] = []
    for name_field, hash_field in ARTIFACT_FIELDS.items():
        left = first["artifacts"][name_field]
        right = second["artifacts"][name_field]
        if left != right:
            failures.append(f"{name_field} differs between isolated builds")
        if left["sha256"] != left["declaredSha256"]:
            failures.append(f"{name_field} does not match its first-build manifest")
        if right["sha256"] != right["declaredSha256"]:
            failures.append(f"{name_field} does not match its second-build manifest")
        if left["sha256"] != expected.get(hash_field):
            failures.append(f"{name_field} does not match the public candidate manifest")
    identity_fields = (
        "usbRecoveryBuildId",
        "bootloaderUpstreamCommit",
        "sourceDateEpoch",
        "armGccVersion",
        "cmakeVersion",
        "buildScriptSha256",
        "patcherSha256",
        "publicKeyId",
    )
    for field in identity_fields:
        values = (first["manifest"].get(field), second["manifest"].get(field), expected.get(field))
        if len(set(values)) != 1:
            failures.append(f"{field} differs between builds or the public manifest")
    return failures


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write-proof", action="store_true")
    parser.add_argument("--proof", type=Path, default=DEFAULT_PROOF)
    args = parser.parse_args()
    expected = json.loads(PUBLIC_MANIFEST.read_text(encoding="utf-8"))
    with tempfile.TemporaryDirectory(prefix="door-bootloader-repro-") as directory:
        base = Path(directory)
        first = build_once(base, "first")
        second = build_once(base, "second")
    failures = compare_runs(first, second, expected)
    artifact_hashes = {
        field: first["artifacts"][field]["sha256"] for field in ARTIFACT_FIELDS
    }
    payload = {
        "schemaVersion": 1,
        "generatedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
        "passed": not failures,
        "usbRecoveryBuildId": expected.get("usbRecoveryBuildId"),
        "bootloaderUpstreamCommit": expected.get("bootloaderUpstreamCommit"),
        "sourceDateEpoch": expected.get("sourceDateEpoch"),
        "armGccVersion": expected.get("armGccVersion"),
        "cmakeVersion": expected.get("cmakeVersion"),
        "buildScriptSha256": expected.get("buildScriptSha256"),
        "patcherSha256": expected.get("patcherSha256"),
        "artifactHashes": artifact_hashes,
        "failures": failures,
    }
    if failures:
        print("Bootloader reproducibility: FAIL")
        for failure in failures:
            print(f"- {failure}")
        return 1
    print("Bootloader reproducibility: PASS")
    for field, digest in artifact_hashes.items():
        print(f"- {field}: {digest}")
    if args.write_proof:
        args.proof.parent.mkdir(parents=True, exist_ok=True)
        args.proof.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
        print(f"Recorded {args.proof}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
