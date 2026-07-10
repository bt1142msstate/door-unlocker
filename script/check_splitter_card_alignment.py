#!/usr/bin/env python3
"""Verify the separated splitter cards remain aligned to their three wire anchors."""

from __future__ import annotations

import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HTML = (ROOT / "phase-1-desk-test-wiring.html").read_text()
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
        'id="positiveSplitterOutputLeft"',
        'id="positiveSplitterOutputRight"',
        'id="positiveSplitterInput"',
        'id="groundSplitterOutputLeft"',
        'id="groundSplitterOutputRight"',
        'id="groundSplitterInput"',
    )
    for marker in required:
        if marker not in HTML:
            raise AssertionError(f"Missing separated splitter marker: {marker}")

    card_width = css_value(".splitter-card", "width")
    image_width = css_value(".splitter-visual", "width")
    positive_left = css_value(".positive-splitter-card", "left")
    ground_left = css_value(".ground-splitter-card", "left")
    positive_right = positive_left + card_width
    gap = ground_left - positive_right
    if gap != 4:
        raise AssertionError(f"Expected a 4px splitter-card gap, found {gap:g}px")

    # Port centers measured from the generated 529px-wide straight splitter asset.
    output_left_ratio = 0.319
    output_right_ratio = 0.662
    input_ratio = 0.504

    print("Separated splitter alignment")
    for name, card_left, center in (
        ("positive", positive_left, 630.0),
        ("ground", ground_left, 730.0),
    ):
        image_left = card_left + (card_width - image_width) / 2
        close(f"{name} card center", card_left + card_width / 2, center)
        close(f"{name} left output", image_left + output_left_ratio * image_width, center - 10)
        close(f"{name} right output", image_left + output_right_ratio * image_width, center + 10)
        close(f"{name} bottom input", image_left + input_ratio * image_width, center)

    print(f"- card gap: {gap:g}px")
    print("Separated splitter alignment: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
