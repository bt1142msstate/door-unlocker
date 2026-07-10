#!/usr/bin/env python3
"""Validate the dimension contracts used by the Phase 2 HTML cutaway."""

from __future__ import annotations

import json
import math
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DIMENSIONS_PATH = ROOT / "cad" / "phase2-dimensions.json"
HTML_PATH = ROOT / "phase-1-desk-test-wiring.html"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def overlaps(first_min: float, first_max: float, second_min: float, second_max: float) -> bool:
    return first_min < second_max and first_max > second_min


def main() -> int:
    dimensions = json.loads(DIMENSIONS_PATH.read_text())
    html = HTML_PATH.read_text()

    enclosure = dimensions["enclosure"]
    plate = dimensions["printed_parts"][0]["dimensions"]
    rail = dimensions["slide_mount"]
    strips = dimensions["adhesive_mount"]
    components = dimensions["components"]
    wire_routing = dimensions["wire_routing_channels"]

    require('id="mountingPlateCanvas"' in html, "3D canvas is missing")
    require('id="mountCutawayToggle"' in html, "component cutaway control is missing")
    require('id="mountHarnessToggle"' in html, "harness inspection control is missing")
    require("const modelDimensions" in html, "dimension-driven model object is missing")
    require("addBreadboardAndXiao" in html, "breadboard/XIAO detail model is missing")
    require("addServoModel" in html, "servo detail model is missing")
    require("addInlineSplitters" in html, "inline splitter detail model is missing")
    require("addWireRoutingChannels" in html, "wire-routing channel model is missing")
    require("addCompleteWireHarness" in html, "connected wire harness model is missing")
    require("upperSolarConflict" in html, "solar conflict envelope is missing")
    require('viewBox="0 0 1120 1900"' in html, "bench wiring map no longer uses the vertical enclosure layout")
    require('class="housing-outline"' in html, "bench wiring map enclosure silhouette is missing")
    require("transform: scale(.34)" in html, "print scale no longer fits the full vertical wiring map")

    for value in (
        enclosure["outer_width"],
        enclosure["outer_depth"],
        enclosure["outer_height"],
        plate["width"],
        plate["depth"],
        plate["height"],
    ):
        require(str(value) in html, f"HTML does not contain required dimension {value}")

    computed_head = rail["rail_neck_width"] + 2 * rail["rail_depth"] / math.tan(
        math.radians(rail["face_angle_degrees_from_mounting_surface"])
    )
    require(abs(computed_head - rail["rail_head_width"]) < 0.01, "dovetail head-width formula drifted")

    computed_channel_neck = rail["rail_neck_width"] + 2 * rail["channel_clearance_per_side"]
    require(computed_channel_neck < computed_head, "female neck no longer captures the male rail head")
    require(rail["channel_length"] > rail["rail_length"], "channel must remain longer than the rail")

    strip = strips["selected_strip"]["dimensions_mm"]
    layout = strips["back_plate_layout"]
    used_width = 2 * strip["width"] + layout["gap_between_columns"]
    used_height = 2 * strip["length"] + layout["gap_between_rows"]
    require(used_width <= plate["width"], "Command strips exceed plate width")
    require(used_height <= plate["height"], "Command strips exceed plate height")

    servo_pocket = components["servo_front_exposure_pocket"]
    pocket_min = servo_pocket["center_z"] - servo_pocket["height"] / 2
    pocket_max = servo_pocket["center_z"] + servo_pocket["height"] / 2
    panel_height = components["solar_panel_series_pair"]["height"] / 2
    lower_panel_center = 61
    upper_panel_center = 172
    require(
        not overlaps(
            lower_panel_center - panel_height / 2,
            lower_panel_center + panel_height / 2,
            pocket_min,
            pocket_max,
        ),
        "lower solar panel unexpectedly overlaps the servo pocket",
    )
    require(
        overlaps(
            upper_panel_center - panel_height / 2,
            upper_panel_center + panel_height / 2,
            pocket_min,
            pocket_max,
        ),
        "upper solar conflict envelope no longer represents the known collision",
    )

    buck = components["lm2596_buck_current"]
    require(
        (buck["width"], buck["height"], buck["depth"]) == (57, 36, 14),
        "LM2596 envelope must remain 57 x 36 x 14mm",
    )
    splitters = components["xalxmaw_inline_splitter_pair"]
    require(
        (splitters["single_width"], splitters["single_depth"], splitters["single_height"]) == (32, 13.5, 13),
        "Inline splitter envelope must remain 32 x 13.5 x 13mm in the modeled orientation",
    )
    require("B0B28GYYL2" in html, "purchased inline splitter listing is missing")

    require(wire_routing["length"] == 83, "wire-routing channel length drifted")
    require(len(wire_routing["lanes"]) == 10, "wire-routing model must keep ten dedicated lanes")
    require(
        [lane["awg"] for lane in wire_routing["lanes"]] == [22] * 5 + [16] * 5,
        "wire-routing lane gauges drifted",
    )
    require(len(wire_routing["harness_connections"]) == 10, "complete harness must keep ten routed connections")
    require(
        {connection["lane"] for connection in wire_routing["harness_connections"]}
        == {lane["name"] for lane in wire_routing["lanes"]},
        "every routing lane must map to exactly one harness connection",
    )
    require(
        all(lane["clear_width"] > lane["estimated_wire_outer_diameter"] for lane in wire_routing["lanes"]),
        "a wire-routing lane no longer has insertion clearance",
    )

    print("Phase 2 HTML model validation: PASS")
    print(f"- Enclosure: {enclosure['outer_width']} x {enclosure['outer_depth']} x {enclosure['outer_height']} mm")
    print(f"- Plate: {plate['width']} x {plate['depth']} x {plate['height']} mm")
    print(f"- Dovetail head: {computed_head:.4f} mm; capture overlap retained")
    print("- Four Command strip pairs fit the documented plate footprint")
    print("- Purchased inline splitter pair matches the 32 x 13.5 x 13mm model contract")
    print("- Ten dedicated rear-wall wire lanes map one-to-one to the complete harness")
    print("- Bench wiring cards and print view use the 1120 x 1900 enclosure-stack layout")
    print("- Lower solar panel clears the servo; upper panel collision remains explicitly modeled")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
