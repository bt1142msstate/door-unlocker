#!/usr/bin/env python3
"""Record a verified intentional Mac BLE OTA run for the current firmware package."""

from __future__ import annotations

import datetime as dt
import hashlib
import json
import re
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
TRACE_PATH = Path.home() / "Library/Application Support/DoorUnlockerAdmin/startup-timing.log"
PACKAGE_PATH = ROOT / "dist/DoorUnlockerXiao-signed-dfu.zip"
PROOF_PATH = ROOT / "docs/firmware-release-proof.json"
EVIDENCE_DIR = ROOT / "docs/ota-evidence"
LINE = re.compile(r"^(?P<time>\S+) DUMacStartup (?P<uptime>\d+)ms (?P<event>.+)$")


def application_payload_sha256(path: Path) -> str:
    with zipfile.ZipFile(path) as archive:
        manifest = json.loads(archive.read("manifest.json"))["manifest"]["application"]
        return hashlib.sha256(archive.read(manifest["bin_file"])).hexdigest()


def package_payload_sha256(path: Path) -> str:
    """Hash the signed package contents independently of ZIP container metadata."""
    digest = hashlib.sha256()
    with zipfile.ZipFile(path) as archive:
        names = sorted(info.filename for info in archive.infolist() if not info.is_dir())
        for name in names:
            digest.update(name.encode("utf-8"))
            digest.update(b"\0")
            digest.update(archive.read(name))
            digest.update(b"\0")
    return digest.hexdigest()


def firmware_version() -> str:
    source = (ROOT / "firmware/DoorUnlockerXiao/DoorUnlockerXiao.ino").read_text(encoding="utf-8")
    match = re.search(r'CONTROLLER_FIRMWARE_VERSION\[\] = "([^"]+)"', source)
    if not match:
        raise SystemExit("Could not read the controller firmware version")
    return match.group(1)


def parse_time(value: str) -> dt.datetime:
    return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))


def parsed_events(text: str) -> list[tuple[dt.datetime, int, str]]:
    events: list[tuple[dt.datetime, int, str]] = []
    for line in text.splitlines():
        match = LINE.match(line)
        if match:
            events.append(
                (parse_time(match.group("time")), int(match.group("uptime")), match.group("event"))
            )
    return sorted(events, key=lambda event: event[0])


def main() -> int:
    target = firmware_version()
    events = parsed_events(TRACE_PATH.read_text(encoding="utf-8", errors="replace"))

    stable_index = next(
        (index for index in range(len(events) - 1, -1, -1)
         if events[index][2] == f"firmware_update_stable_verified {target}"),
        None,
    )
    if stable_index is None:
        raise SystemExit(f"No delayed stable BLE verification for firmware {target} was found")

    entry_index = next(
        (index for index in range(stable_index - 1, -1, -1)
         if events[index][2] == "wireless_command_sent firmware update"),
        None,
    )
    if entry_index is None:
        raise SystemExit("No signed BLE firmware-entry command precedes verification")

    run = events[entry_index:stable_index + 1]
    tuning = next((event for _, _, event in run if event.startswith("firmware_update_tuning prn=")), None)
    ota_state = next(
        (
            time
            for time, _, event in run
            if event.startswith("wireless_state_received firmware_update:ota_dfu")
        ),
        None,
    )
    upload_start = next((time for time, _, event in run if event.endswith("progress=0") and "Uploading firmware" in event), None)
    upload_end = next((time for time, _, event in run if event == "firmware_update_uploaded"), None)
    bootloader_selection = next(
        (event for _, _, event in run if event.startswith("firmware_bootloader_selected ")),
        None,
    )
    firmware_observations = [
        time
        for time, _, event in run
        if event == f"wireless_state_received firmware_version:{target}"
    ]
    if (
        ota_state is None
        or upload_start is None
        or upload_end is None
        or bootloader_selection is None
        or not firmware_observations
    ):
        raise SystemExit("The OTA upload did not provide complete start/end telemetry")

    started_at, _, _ = events[entry_index]
    verified_at = firmware_observations[0]
    stable_at, _, _ = events[stable_index]
    if (stable_at - verified_at).total_seconds() < 15:
        raise SystemExit("Stable firmware verification occurred less than 15 seconds after reboot verification")
    selection = dict(
        field.split("=", 1)
        for field in bootloader_selection.split()[1:]
        if "=" in field
    )
    run_id = started_at.strftime("%Y%m%dT%H%M%SZ") + "-mac"
    payload = {
        "durationSeconds": round((stable_at - started_at).total_seconds(), 3),
        "endedAt": stable_at.isoformat().replace("+00:00", "Z"),
        "entryCommandElapsedMilliseconds": round((ota_state - started_at).total_seconds() * 1_000),
        "entryCommandOver": "ble",
        "message": (
            f"Trusted Mac sent a signed BLE OTA command, uploaded the package, "
            f"rebooted, and verified {target} over BLE."
        ),
        "package": {
            "bytes": PACKAGE_PATH.stat().st_size,
            "sha256": hashlib.sha256(PACKAGE_PATH.read_bytes()).hexdigest(),
            "payloadSha256": package_payload_sha256(PACKAGE_PATH),
            "applicationPayloadSha256": application_payload_sha256(PACKAGE_PATH),
        },
        "bootloaderName": selection.get("name"),
        "packageProfile": selection.get("profile"),
        "packetReceiptNotificationParameter": (
            int(tuning.rsplit("=", 1)[1]) if tuning is not None else None
        ),
        "result": "pass",
        "runId": run_id,
        "startedAt": started_at.isoformat().replace("+00:00", "Z"),
        "verifiedAt": verified_at.isoformat().replace("+00:00", "Z"),
        "stableVerifiedAt": stable_at.isoformat().replace("+00:00", "Z"),
        "targetFirmware": target,
        "uploadSeconds": round((upload_end - upload_start).total_seconds(), 3),
        "usbRecoveryCommandUsed": False,
        "verifiedOver": "ble",
    }
    EVIDENCE_DIR.mkdir(parents=True, exist_ok=True)
    evidence_path = EVIDENCE_DIR / f"{run_id}.json"
    evidence_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    PROOF_PATH.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"Recorded BLE OTA proof for {target}: {payload['durationSeconds']:.3f}s total")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
