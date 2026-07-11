#!/usr/bin/env python3
"""Verify the layered XIAO, breadboard, and jumper coordinates stay aligned."""

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
        'src="assets/component-breadboard-red-layer.png"',
        'src="assets/component-xiao-top-down-layer.png"',
        'd="M2 0 V103.7 H19.5"',
        'd="M151 237 V79.1 H136.3"',
        'd="M136 237 V91.4"',
        'id="controllerPowerWire"',
        'id="controllerGroundWire"',
        'id="controllerSignalWire"',
        'const controllerPower = assemblyPoint(151, 1)',
        'const controllerGround = assemblyPoint(136, 1)',
        'const controllerSignal = assemblyPoint(2, 0)',
    )
    for marker in required:
        if marker not in HTML:
            raise AssertionError(f"Missing layered controller marker: {marker}")

    for path_id in ("controllerPowerWire", "controllerGroundWire", "controllerSignalWire"):
        rendered = re.search(rf'id="{path_id}"[^>]*\sd="([^"]+)"', RUNTIME_HTML)
        if not rendered:
            raise AssertionError(f"Runtime controller path {path_id} has no geometry")

    assembly_width = css_value(".controller-assembly", "width")
    assembly_height = 237.0
    xiao_left = css_value(".controller-assembly .xiao-layer", "left")
    xiao_top = css_value(".controller-assembly .xiao-layer", "top")
    xiao_width = css_value(".controller-assembly .xiao-layer", "width")
    xiao_height = css_value(".controller-assembly .xiao-layer", "height")

    # Pixel centers measured once from the two generated source layers.
    breadboard_width, breadboard_height = 863.0, 1219.0
    column_x = {"A": 100.0, "C": 219.5, "H": 640.0, "I": 700.0}
    row_y = {6: 406.5, 7: 470.0, 8: 533.0, 12: 785.5}
    xiao_width_px, xiao_height_px = 766.0, 996.0
    left_pin_x, right_pin_x = 27.0, 735.0
    pin_y = {1: 196.0, 2: 305.0, 3: 415.0, 7: 852.0}

    board_x = lambda column: column_x[column] / breadboard_width * assembly_width
    board_y = lambda row: row_y[row] / breadboard_height * assembly_height
    controller_x = lambda pin: xiao_left + pin / xiao_width_px * xiao_width
    controller_y = lambda pin: xiao_top + pin / xiao_height_px * xiao_height

    print("Controller / breadboard alignment")
    close("left header to column C", controller_x(left_pin_x), board_x("C"))
    close("right header to column H", controller_x(right_pin_x), board_x("H"))
    close("pin 1 to row 6", controller_y(pin_y[1]), board_y(6))
    close("GND pin 2 to row 7", controller_y(pin_y[2]), board_y(7))
    close("D2 pin 3 to row 8", controller_y(pin_y[3]), board_y(8))
    close("pin 7 to row 12", controller_y(pin_y[7]), board_y(12))
    close("yellow plug to column A", 19.5, board_x("A"))
    close("yellow plug to row 8", 103.7, board_y(8))
    close("power plugs to column I", 136.3, board_x("I"))
    close("red plug to row 6", 79.1, board_y(6))
    close("ground plug to row 7", 91.4, board_y(7))
    print("Controller / breadboard alignment: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
