#!/usr/bin/env python3
"""Build a deterministic signed Adafruit legacy DFU 0.8 package."""

from __future__ import annotations

import argparse
import hashlib
import json
import struct
import zipfile
from pathlib import Path

def main() -> int:
    from ecdsa import SigningKey
    from ecdsa.util import sigencode_string

    parser = argparse.ArgumentParser()
    parser.add_argument("--image-type", choices=("application", "bootloader"), required=True)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--device-type", type=lambda value: int(value, 0), required=True)
    parser.add_argument(
        "--device-revision",
        type=lambda value: int(value, 0),
        default=0xFFFF,
        help="Hardware revision enforced by the bootloader (52840 for nRF52840 bootloader images).",
    )
    parser.add_argument(
        "--softdevice-request",
        type=lambda value: int(value, 0),
        action="append",
        required=True,
    )
    parser.add_argument("--key", type=Path, required=True)
    args = parser.parse_args()

    payload = args.input.read_bytes()
    digest = hashlib.sha256(payload).digest()
    init_packet = build_init_packet(
        device_type=args.device_type,
        device_revision=args.device_revision,
        softdevice_requests=args.softdevice_request,
        payload_length=len(payload),
        payload_hash=digest,
    )
    signing_key = SigningKey.from_pem(args.key.read_text(encoding="utf-8"))
    signature = signing_key.sign_deterministic(
        init_packet,
        hashfunc=hashlib.sha256,
        sigencode=sigencode_string,
    )
    if len(signature) != 64:
        raise SystemExit("P-256 signature must contain exactly 64 bytes")

    stem = args.input.stem
    bin_name = f"{stem}.bin"
    dat_name = f"{stem}.dat"
    dat_bytes = init_packet + signature
    manifest = {
        "manifest": {
            args.image_type: {
                "bin_file": bin_name,
                "dat_file": dat_name,
                "init_packet_data": {
                    "application_version": 0xFFFFFFFF,
                    "device_revision": args.device_revision,
                    "device_type": args.device_type,
                    "ext_packet_id": 2,
                    "firmware_hash": digest.hex(),
                    "firmware_length": len(payload),
                    "init_packet_ecds": signature.hex(),
                    "softdevice_req": args.softdevice_request,
                },
            },
            "dfu_version": 0.8,
        }
    }
    manifest_bytes = (json.dumps(manifest, indent=4, sort_keys=True) + "\n").encode()

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(
        args.output,
        "w",
        compression=zipfile.ZIP_DEFLATED,
        compresslevel=9,
    ) as archive:
        write_member(archive, bin_name, payload)
        write_member(archive, dat_name, dat_bytes)
        write_member(archive, "manifest.json", manifest_bytes)
    return 0


def build_init_packet(
    *,
    device_type: int,
    device_revision: int,
    softdevice_requests: list[int],
    payload_length: int,
    payload_hash: bytes,
) -> bytes:
    if len(payload_hash) != 32:
        raise ValueError("DFU 0.8 requires a SHA-256 payload hash")
    if not softdevice_requests:
        raise ValueError("At least one SoftDevice requirement is required")
    header = struct.pack(
        "<HHIH",
        device_type,
        device_revision,
        0xFFFFFFFF,
        len(softdevice_requests),
    )
    requirements = b"".join(struct.pack("<H", value) for value in softdevice_requests)
    extension = struct.pack("<II", 2, payload_length)
    return header + requirements + extension + payload_hash


def write_member(archive: zipfile.ZipFile, name: str, data: bytes) -> None:
    info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
    info.compress_type = zipfile.ZIP_DEFLATED
    info.external_attr = 0o100644 << 16
    archive.writestr(info, data, compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)


if __name__ == "__main__":
    raise SystemExit(main())
