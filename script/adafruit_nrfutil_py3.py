#!/usr/bin/env python3
"""Run adafruit-nrfutil signing commands with its Python 3 key-loader fixed."""

import binascii
from pathlib import Path

from ecdsa import SigningKey
from nordicsemi.dfu.signing import Signing
import nordicsemi.dfu.manifest as manifest_module


def load_key(self: Signing, filename: str) -> None:
    self.sk = SigningKey.from_pem(Path(filename).read_text(encoding="utf-8"))


Signing.load_key = load_key


class _ManifestBinascii:
    @staticmethod
    def hexlify(value: bytes) -> str:
        return binascii.hexlify(value).decode("ascii")


manifest_module.binascii = _ManifestBinascii

from nordicsemi.__main__ import cli  # noqa: E402


if __name__ == "__main__":
    cli()
