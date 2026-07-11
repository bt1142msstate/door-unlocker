#!/usr/bin/env python3
"""Verify the joined splitter pair remains aligned to its wire anchors."""

from __future__ import annotations

import re
from pathlib import Path

from html_runtime import render_html


ROOT = Path(__file__).resolve().parents[1]
HTML = (ROOT / "phase-1-desk-test-wiring.html").read_text()
RUNTIME_HTML = render_html(ROOT / "phase-1-desk-test-wiring.html")
TOLERANCE = 1.0


def css_value(selector: str, property_name: str) -> float:
    block = re.search(rf"{re.escape(selector)}\s*\{{(?P<body>.*?)\}}", HTML, re.DOTALL)
    if not block:
        raise AssertionError(f"Missing CSS selector {selector}")
    value = re.search(rf"{re.escape(property_name)}:\s*([\d.]+)px", block.group("body"))
    if not value:
        raise AssertionError(f"Missing {property_name} in {selector}")
    return float(value.group(1))


def close(label: str, actual: float, expected: float) -> None:
    error = abs(actual - expected)
    if error > TOLERANCE:
        raise AssertionError(f"{label}: {actual:.2f}px vs {expected:.2f}px ({error:.2f}px error)")
    print(f"- {label}: {actual:.2f}px ({error:.2f}px error)")


def main() -> int:
    required = (
        'data-node="splitter-positive"',
        'data-node="splitter-ground"',
        'const positiveInput = point(positiveSplitterRect, 0.504, 0.963)',
        'const groundInput = point(groundSplitterRect, 0.504, 0.963)',
        'const positiveOutputServo = point(positiveSplitterRect, 0.319, 0.061)',
        'const positiveOutputBuck = point(positiveSplitterRect, 0.662, 0.061)',
        'const groundOutputBuck = point(groundSplitterRect, 0.319, 0.061)',
        'const groundOutputServo = point(groundSplitterRect, 0.662, 0.061)',
    )
    for marker in required:
        if marker not in HTML:
            raise AssertionError(f"Missing joined splitter marker: {marker}")

    for path_id in (
        "xt30PositiveWire",
        "xt30GroundWire",
        "servoPositiveWire",
        "servoGroundWire",
        "buckInputPositiveWire",
        "buckInputGroundWire",
    ):
        rendered = re.search(rf'id="{path_id}"[^>]*\sd="([^"]+)"', RUNTIME_HTML)
        if not rendered:
            raise AssertionError(f"Runtime splitter path {path_id} has no geometry")

    card_width = css_value(".splitter-card", "width")
    image_width = css_value(".splitter-visual", "width")
    positive_left = css_value(".positive-splitter-card", "left")
    ground_left = css_value(".ground-splitter-card", "left")
    positive_right = positive_left + card_width
    gap = ground_left - positive_right
    if gap != 0:
        raise AssertionError(f"Expected joined splitter bodies with a 0px gap, found {gap:g}px")

    # Port centers measured from the generated 529px-wide straight splitter asset.
    output_left_ratio = 0.319
    output_right_ratio = 0.662
    input_ratio = 0.504

    print("Joined splitter alignment")
    for name, card_left, center in (
        ("positive", positive_left, 652.0),
        ("ground", ground_left, 708.0),
    ):
        image_left = card_left + (card_width - image_width) / 2
        close(f"{name} card center", card_left + card_width / 2, center)
        close(f"{name} left output", image_left + output_left_ratio * image_width, center - 10)
        close(f"{name} right output", image_left + output_right_ratio * image_width, center + 10)
        close(f"{name} bottom input", image_left + input_ratio * image_width, center)

    print(f"- card gap: {gap:g}px")
    close("visible body join", positive_left + image_width, ground_left)
    print("Joined splitter alignment: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
