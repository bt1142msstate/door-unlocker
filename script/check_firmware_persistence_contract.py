#!/usr/bin/env python3
"""Fail when controller persistence loses transactional safety invariants."""

from pathlib import Path
import sys


SOURCE = Path("firmware/DoorUnlockerXiao/DoorUnlockerXiao.ino")
text = SOURCE.read_text()

checks = {
    "dual pairing slots": all(token in text for token in (
        "PAIRINGS_SLOT_A_FILENAME", "PAIRINGS_SLOT_B_FILENAME", "PAIRINGS_TEMP_FILENAME"
    )),
    "pairing snapshot verification": (
        "readPairingsSnapshot(PAIRINGS_TEMP_FILENAME, &verified)" in text
        and "verified.generation != nextGeneration" in text
    ),
    "failed key append rolls back RAM": all(token in text for token in (
        "uint8_t addedIndex = pairedPublicKeyCount;",
        "if (!savePairings()) {",
        "pairedPublicKeyCount--;",
        "memset(pairedPublicKeys[addedIndex], 0, P256_PUBLIC_KEY_LEN);",
    )),
    "failed existing-key update restores name": (
        "copyDeviceName(previousName, pairedDeviceNames[existingIndex]" in text
        and "rejectCommandFor(connHandle, \"pairing save failed\")" in text
    ),
    "storage repair restores settings": all(token in text for token in (
        "bool repairInternalStorage()",
        "InternalFS.format()",
        "saveLockName()",
        "saveServoAngles()",
        "saveUnlockHoldTimeout()",
        "savePairings()",
    )),
}

failed = [name for name, passed in checks.items() if not passed]
for name, passed in checks.items():
    print(f"{'PASS' if passed else 'FAIL'}: {name}")

if failed:
    print("Firmware persistence contract: FAIL", file=sys.stderr)
    sys.exit(1)

print("Firmware persistence contract: PASS")
