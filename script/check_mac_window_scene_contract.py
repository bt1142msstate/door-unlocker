#!/usr/bin/env python3
"""Prevent the Mac app from restoring a blank placeholder Settings window."""

import re
from pathlib import Path


SOURCE = Path(
    "mac/DoorUnlockerAdmin/Sources/DoorUnlockerAdmin/App/DoorUnlockerAdminApp.swift"
)


def main() -> int:
    text = SOURCE.read_text(encoding="utf-8")
    checks = {
        "main content owns the launch scene": (
            'WindowGroup("Door Unlocker", id: "main")' in text
            and "ContentView(store: store)" in text
        ),
        "no placeholder Settings scene exists": (
            "Settings {" not in text and "EmptyView()" not in text
        ),
        "no parallel AppKit main-window presenter exists": (
            "DoorAdminMainWindowPresenter" not in text
        ),
        "saved windows cannot restore removed placeholder scenes": (
            re.search(
                r"func\s+applicationSupportsSecureRestorableState\b[^\{]*\{\s*false\s*\}",
                text,
                re.DOTALL,
            )
            is not None
        ),
    }

    failures = [name for name, passed in checks.items() if not passed]
    for name, passed in checks.items():
        print(f"{'PASS' if passed else 'FAIL'}: {name}")

    if failures:
        print("Mac window scene contract: FAIL")
        return 1
    print("Mac window scene contract: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
