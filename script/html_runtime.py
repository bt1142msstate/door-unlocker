#!/usr/bin/env python3
"""Render local HTML with Chrome so validators inspect runtime DOM geometry."""

from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path


def _chrome_binary() -> str:
    candidates = (
        os.environ.get("CHROME_BIN"),
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        shutil.which("google-chrome"),
        shutil.which("google-chrome-stable"),
        shutil.which("chromium"),
        shutil.which("chromium-browser"),
    )
    for candidate in candidates:
        if candidate and Path(candidate).is_file():
            return candidate
    raise AssertionError(
        "Runtime HTML validation requires Chrome or Chromium; set CHROME_BIN when it is not on PATH"
    )


def render_html(path: Path, *, virtual_time_budget_ms: int = 3000) -> str:
    """Return the DOM after local scripts, image layout, and animation frames run."""

    result = subprocess.run(
        [
            _chrome_binary(),
            "--headless=new",
            "--disable-background-networking",
            "--disable-extensions",
            "--disable-gpu",
            "--disable-sync",
            "--no-first-run",
            "--no-sandbox",
            "--allow-file-access-from-files",
            f"--virtual-time-budget={virtual_time_budget_ms}",
            "--dump-dom",
            path.resolve().as_uri(),
        ],
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )
    if result.returncode != 0 or not result.stdout.strip():
        detail = result.stderr.strip()[-1200:]
        raise AssertionError(f"Chrome could not render {path.name}: {detail}")
    return result.stdout
