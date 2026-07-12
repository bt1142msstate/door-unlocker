#!/usr/bin/env python3
"""Validate the dimension contracts used by the Phase 2 HTML cutaway."""

from __future__ import annotations

import base64
import json
import math
import re
import struct
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DIMENSIONS_PATH = ROOT / "cad" / "phase2-dimensions.json"
HTML_PATH = ROOT / "phase-1-desk-test-wiring.html"
SCAD_PATH = ROOT / "cad" / "phase2-enclosure.scad"
XIAO_GLB_PATH = ROOT / "assets" / "models" / "xiao-nrf52840-sense-official.glb"
XIAO_WRAPPER_PATH = ROOT / "assets" / "models" / "xiao-nrf52840-sense-official.js"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def overlaps(first_min: float, first_max: float, second_min: float, second_max: float) -> bool:
    return first_min < second_max and first_max > second_min


def css_px(html: str, selector: str, property_name: str) -> float:
    block = re.search(rf"{re.escape(selector)}\s*\{{(?P<body>.*?)\}}", html, re.DOTALL)
    require(block is not None, f"missing CSS selector {selector}")
    value = re.search(rf"{re.escape(property_name)}:\s*([\d.]+)px", block.group("body"))
    require(value is not None, f"missing {property_name} in {selector}")
    return float(value.group(1))


def main() -> int:
    dimensions = json.loads(DIMENSIONS_PATH.read_text())
    html = HTML_PATH.read_text()
    scad = SCAD_PATH.read_text()

    enclosure = dimensions["enclosure"]
    plate = dimensions["printed_parts"][0]["dimensions"]
    rail = dimensions["slide_mount"]
    strips = dimensions["adhesive_mount"]
    components = dimensions["components"]
    wire_routing = dimensions["wire_routing_channels"]

    require('id="mountingPlateCanvas"' in html, "3D canvas is missing")
    require('id="mountCutawayToggle"' in html, "component cutaway control is missing")
    require('id="mountHarnessToggle"' in html, "harness inspection control is missing")
    require('id="mountFocusReadout"' in html, "component focus readout is missing")
    require(html.count('data-model-focus="') == 8, "component inspector must expose eight focus targets")
    require("const componentFocusProfiles" in html and "function focusComponent" in html, "component focus camera profiles are missing")
    require("targetPivotX" in html and "targetPivotY" in html, "component focus centering is missing")
    require('minimumDistance = activeComponentFocus === "overview" ? 70 : 55' in html, "deep component zoom limit drifted")
    require("dataset.targetCameraDistance" in html and "dataset.cameraDistance" in html, "3D zoom telemetry is missing")
    require("const modelDimensions" in html, "dimension-driven model object is missing")
    require("addBreadboardAndXiao" in html, "breadboard/XIAO detail model is missing")
    require("Official XIAO STEP" in html, "official XIAO 3D reference link is missing")
    require("GLTFLoader" in html and "xiaoOfficialModel" in html, "official XIAO GLB loader is missing")
    require(
        "anchor.rotation.z = Math.PI / 2" in html
        and "faceOrientation.rotation.x = Math.PI / 2" in html,
        "official XIAO orientation no longer places USB-C toward the servo and the component face outward",
    )
    require(
        'src="assets/models/xiao-nrf52840-sense-official.js"' in html,
        "filesystem-safe official XIAO model wrapper is missing",
    )
    require("addServoModel" in html, "servo detail model is missing")
    require("addInlineSplitters" in html, "inline splitter detail model is missing")
    require(
        'splitterGroup.name = centerX < 0 ? "positiveInlineSplitter" : "groundInlineSplitter"' in html
        and 'outputBody.name = "twoOutputWideHousing"' in html
        and 'inputBody.name = "singleInputNarrowHousing"' in html
        and "const inspectionWindow = roundedRectMesh" in html
        and "const couplingTab = roundedRectMesh" in html
        and "const internalBus = roundedRectMesh" in html,
        "high-detail inline splitter geometry is missing",
    )
    require("addWireRoutingChannels" in html, "wire-routing channel model is missing")
    require("addCompleteWireHarness" in html, "connected wire harness model is missing")
    require("upperSolarConflict" not in html, "Phase 2 solar hardware leaked into the Phase 1.5 viewer")
    require("const statusLed" not in html, "future external status LED leaked into the Phase 1.5 viewer")
    require("function updateBackingVisibility" in html and "backViewAmount" in html, "back-side occlusion handling is missing")
    require('viewBox="0 0 1120 2160"' in html, "bench wiring map no longer uses the vertical enclosure layout")
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
        (buck["width"], buck["height"], buck["depth"]) == (60, 40, 10),
        "Purchased LM2596 envelope must remain 60 x 40 x 10mm",
    )
    require("B0DM946DHG" in buck["source"], "purchased LM2596 source is missing")
    breadboard = components["mini_breadboard_170_point"]
    require(
        (breadboard["width"], breadboard["height"], breadboard["depth"]) == (35, 47, 8.5),
        "Purchased breadboard envelope must remain 35 W x 47 H x 8.5 D mm",
    )
    require("B01KKE602W" in breadboard["source"], "purchased breadboard source is missing")
    splitters = components["xalxmaw_inline_splitter_pair"]
    require(
        (splitters["single_width"], splitters["single_depth"], splitters["single_height"]) == (32, 13.5, 13),
        "Inline splitter envelope must remain 32 x 13.5 x 13mm in the modeled orientation",
    )
    require("B0B28GYYL2" in html, "purchased inline splitter listing is missing")
    require(
        splitters["detail_geometry"]["ports"] == 3
        and splitters["detail_geometry"]["levers"] == 3
        and splitters["detail_geometry"]["output_body_width"] == 13
        and splitters["detail_geometry"]["input_body_width_estimate"] == 8.2
        and splitters["detail_geometry"]["port_axis"] == "opposing lengthwise end faces"
        and splitters["detail_geometry"]["coupling_tabs"] == 2,
        "inline splitter detail contract drifted",
    )
    require(
        "inputBodyWidth: 8.2" in html
        and "outputBodyLength: 18.5" in html
        and "inputBodyLength: 15.5" in html
        and "panelWithCircularHoles(" in html
        and 'outputEndCap.name = "twoOutputEndCapWithOpenBores"' in html
        and 'inputEndCap.name = "singleInputEndCapWithOpenBore"' in html
        and "const bore = cylinderMesh" in html,
        "inline splitter must retain its narrow input stem, wide output head, and true end-cap openings",
    )

    # Hard-body visuals share the documented approximate 4-5 px/mm scale.
    # Harness leads and the servo arm intentionally extend beyond their component bodies.
    visual_scales = {
        "buck height": css_px(html, ".buck-visual", "height") / buck["width"],
        "splitter length": css_px(html, ".splitter-visual", "height") / splitters["single_width"],
        "splitter width": css_px(html, ".splitter-visual", "width") / splitters["single_depth"],
        "breadboard height": 237 / components["mini_breadboard_170_point"]["height"],
    }
    require(
        all(3.9 <= scale <= 5.1 for scale in visual_scales.values()),
        f"bench component visual scale drifted: {visual_scales}",
    )

    require(wire_routing["length"] == 122, "wire-routing channel length drifted")
    require(len(wire_routing["lanes"]) == 10, "wire-routing model must keep ten dedicated lanes")
    require(
        sum(lane["awg"] == 22 for lane in wire_routing["lanes"]) == 5
        and sum(lane["awg"] == 16 for lane in wire_routing["lanes"]) == 5,
        "wire-routing lane gauges drifted",
    )
    require(len(wire_routing["harness_connections"]) == 9, "complete harness must keep nine active connections")
    lane_names = {lane["name"] for lane in wire_routing["lanes"]}
    connected_lane_names = {connection["lane"] for connection in wire_routing["harness_connections"]}
    require(
        connected_lane_names == lane_names - {"spare_high_current"},
        "the active harness must use every lane except the reserved high-current groove",
    )
    require(
        len(connected_lane_names) == len(wire_routing["harness_connections"]),
        "a routing lane is assigned to more than one active harness connection",
    )
    require(
        all(lane["clear_width"] > lane["estimated_wire_outer_diameter"] for lane in wire_routing["lanes"]),
        "a wire-routing lane no longer has insertion clearance",
    )
    lane_colors = {lane["name"]: lane["color"] for lane in wire_routing["lanes"]}
    require(
        lane_colors
        == {
            "splitter_positive_to_servo": "red",
            "battery_positive_input": "red",
            "spare_high_current": "red",
            "pwm_signal": "yellow",
            "controller_5v": "red",
            "controller_ground": "black",
            "buck_input_positive": "red",
            "buck_input_ground": "black",
            "battery_ground_input": "black",
            "splitter_ground_to_servo": "black",
        },
        f"wire color contract drifted: {lane_colors}",
    )
    require(wire_routing["component_standoff_depth"] == 4, "rear service raceway depth drifted")
    require("serviceRacewayDepth: 4" in html, "HTML component standoff no longer matches the raceway")

    component_z = {
        "battery": components["battery_2s_5000mah"]["layout"]["z"],
        "splitters": components["xalxmaw_inline_splitter_pair"]["layout"]["z"],
        "buck": components["lm2596_buck_current"]["layout"]["z"],
        "breadboard": components["mini_breadboard_170_point"]["layout"]["z"],
        "servo": components["servo_front_exposure_pocket"]["center_z"],
    }
    require(
        list(component_z.values()) == sorted(component_z.values()),
        f"component stack no longer follows battery-to-servo bench order: {component_z}",
    )
    require(
        components["mini_breadboard_170_point"]["layout"]["x"] == 0
        and components["xiao_nrf52840_sense_pinned"]["layout"]["x"] == 0,
        "breadboard and XIAO must remain horizontally centered",
    )
    require(
        components["xalxmaw_inline_splitter_pair"]["layout"]["x_centers"] == [-6.75, 6.75],
        "inline splitters must remain joined side-by-side",
    )
    require(
        components["servo_front_exposure_pocket"]["center_z"] == 231,
        "Phase 1.5 servo opening no longer matches the fitted service cover",
    )
    require(
        "centersX: [-6.75, 6.75]" in html and "centerY: -37.5" in html,
        "HTML splitter layout drifted",
    )
    require("addBuckModel" in html, "vertical buck detail model is missing")
    require("powerSwitchEnvelope" not in html, "obsolete depth-stacked power-switch block returned")
    require("splitter-positive-to-servo" in html, "direct positive servo branch is missing")
    require('name: "controller5V", x: -4' in html and 'material: "wireRed"' in html, "controller 5V groove must remain red")
    require("servo-ground-brown-pigtail" in html and "materials.wireBrown" in html, "servo brown ground pigtail is missing")
    require("materials.wireBlue" not in html, "obsolete blue 5V harness returned")
    require("labelPlane(9, 18" in html and 'lines: ["5.0"]' in html, "realistic 5.0V buck display detail is missing")
    require(
        "const regulator = roundedRectMesh" in html
        and "const diode = roundedRectMesh" in html
        and "const displayButton = roundedRectMesh" in html,
        "detailed procedural buck components are missing",
    )
    require("xiaoFallback" in html and "xiaoFallback.visible = false" in html, "XIAO fallback handling is missing")
    require('dataset.xiaoModel = "official-step"' in html, "official XIAO runtime marker is missing")
    require(
        "publishedHeaderDatum" in html
        and "headerCenterX: 1.741" in html
        and "headerCenterZ: -6.1114" in html
        and "headerEdgeZ: [-13.7314, 1.5086]" in html
        and 'officialHeaders.name = "xiaoOfficialCadAlignedHeaders"' in html
        and "officialModel.add(officialHeaders)" in html
        and 'dataset.xiaoAlignment = "official-cad-hole-centers"' in html,
        "official XIAO headers must remain parented to the exact CAD plated-hole centers",
    )
    require("headerCarrier" in html, "pre-soldered XIAO header carriers are missing")
    require(
        "pitch: 2.54" in html
        and "pinWidth: 0.64" in html
        and "pinLength: 8.2" in html
        and "pinCornerRadius: 0.1" in html
        and "rowCenterX: 7.62" in html
        and "roundedRectMesh(" in html
        and "headerSpec.pinWidth" in html
        and "headerSpec.pinCornerRadius" in html,
        "XIAO headers must retain the published 2.54mm grid and chamfered 0.64mm square-pin profile",
    )
    require(
        "header.position.set(pinX + xiao.centerX, pinY, xiaoZ - 1.7)" in html,
        "fallback XIAO header pins must traverse the controller PCB and seat inside the breadboard",
    )
    require(
        "header.position.set(pinX, officialCad.pinCenterY, edgeZ)" in html
        and "fallbackHeaderHardware.visible = false" in html,
        "official XIAO header pins must replace the fallback overlay and share the CAD transform",
    )
    require(
        components["xiao_nrf52840_sense_pinned"]["header_geometry"]["square_pin"] == 0.64,
        "XIAO header dimension contract drifted",
    )
    require(XIAO_GLB_PATH.is_file(), "official XIAO GLB asset is missing")
    require(XIAO_WRAPPER_PATH.is_file(), "official XIAO filesystem wrapper is missing")
    glb = XIAO_GLB_PATH.read_bytes()
    require(len(glb) > 100_000, "official XIAO GLB is unexpectedly small")
    require(glb[:4] == b"glTF", "official XIAO asset is not a binary glTF file")
    version, declared_length = struct.unpack_from("<II", glb, 4)
    require(version == 2 and declared_length == len(glb), "official XIAO GLB header is invalid")
    wrapper = XIAO_WRAPPER_PATH.read_text()
    encoded_match = re.search(r'XIAO_NRF52840_OFFICIAL_GLB_BASE64 = "([A-Za-z0-9+/=]+)";', wrapper)
    require(encoded_match is not None, "XIAO filesystem wrapper is malformed")
    require(base64.b64decode(encoded_match.group(1)) == glb, "XIAO filesystem wrapper does not match the GLB")
    require('lines: ["5000mAh", "7.4V · 2S", "Li-ion battery"]' in html, "battery label detail is missing")
    require('id="servoGroundUsbBridge"' in html, "explicit 2D crossing bridge support is missing")
    require(
        "doorGroup.visible = doorSurfaceVisible;" in html
        and "adhesiveGroup.visible = true;" in html
        and "plateGroup.visible = true;" in html,
        "back-side rotation must hide only the door surface, not the mounting plate or Command strips",
    )
    require(
        "wire_lane_x = [-28, -22.8, -17.6, -8, -4, 0, 4, 8, 22.8, 28];" in scad,
        "OpenSCAD groove centers no longer match the HTML cutaway",
    )
    require(
        "splitter_x_centers = [-6.75, 6.75];" in scad and "splitter_z = 94.5;" in scad,
        "OpenSCAD splitter placement no longer matches the clean bench stack",
    )

    print("Phase 2 HTML model validation: PASS")
    print(f"- Enclosure: {enclosure['outer_width']} x {enclosure['outer_depth']} x {enclosure['outer_height']} mm")
    print(f"- Plate: {plate['width']} x {plate['depth']} x {plate['height']} mm")
    print(f"- Dovetail head: {computed_head:.4f} mm; capture overlap retained")
    print("- Four Command strip pairs fit the documented plate footprint")
    print("- Purchased inline splitter pair matches the 32 x 13.5 x 13mm model contract")
    print("- Representative hard-body visuals remain within the documented 4-5 px/mm scale")
    print("- Ten dedicated rear-wall grooves carry nine active wires plus one future-switch lane")
    print("- Battery, splitters, vertical buck, centered controller, and servo follow the bench-map order")
    print("- Bench wiring parts and print view use the 1120 x 2160 enclosure-stack layout")
    print("- Phase 1.5 viewer excludes the future Phase 2 solar skin and external status LED")
    print("- Back-side rotation hides only the door surface while preserving the mounting plate and Command strips")
    print("- Buck, battery, and official-reference XIAO geometry retain their detail contracts")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
