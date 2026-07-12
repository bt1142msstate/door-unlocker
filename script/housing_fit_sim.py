#!/usr/bin/env python3
"""Housing and mounting-plate fit calculator for the Door Unlocker prototype."""

from __future__ import annotations

import argparse
import json
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import ClassVar


@dataclass(frozen=True)
class Box:
    name: str
    x: float
    y: float
    z: float
    width: float
    depth: float
    height: float
    clearance: float = 0.0
    kind: str = "component"

    def expanded(self) -> "Box":
        return Box(
            name=f"{self.name}_clearance",
            x=self.x,
            y=self.y,
            z=self.z,
            width=self.width + self.clearance * 2,
            depth=self.depth + self.clearance * 2,
            height=self.height + self.clearance * 2,
            clearance=0.0,
            kind=self.kind,
        )

    @property
    def min_x(self) -> float:
        return self.x - self.width / 2

    @property
    def max_x(self) -> float:
        return self.x + self.width / 2

    @property
    def min_y(self) -> float:
        return self.y - self.depth / 2

    @property
    def max_y(self) -> float:
        return self.y + self.depth / 2

    @property
    def min_z(self) -> float:
        return self.z - self.height / 2

    @property
    def max_z(self) -> float:
        return self.z + self.height / 2

    def intersects(self, other: "Box") -> bool:
        return (
            self.min_x < other.max_x
            and self.max_x > other.min_x
            and self.min_y < other.max_y
            and self.max_y > other.min_y
            and self.min_z < other.max_z
            and self.max_z > other.min_z
        )


@dataclass(frozen=True)
class HousingScenario:
    case_width_mm: float = 72.0
    case_depth_mm: float = 56.0
    case_height_mm: float = 264.0
    wall_mm: float = 3.2
    p1s_build_height_mm: float = 256.0
    plate_width_mm: float = 50.8
    plate_depth_mm: float = 7.0
    plate_height_mm: float = 264.0
    plate_max_height_mm: float = 264.0
    housing_top_margin_mm: float = 4.0
    housing_bottom_margin_mm: float = 1.5
    rail_end_margin_target_mm: float = 8.0
    mount_rail_length_mm: float = 244.0
    mount_channel_length_mm: float = 246.0
    servo_default_center_z_mm: float = 88.9
    servo_center_z_range_mm: ClassVar[tuple[float, float]] = (22.0, 242.0)
    servo_center_z_samples_mm: ClassVar[tuple[float, ...]] = (22.0, 40.0, 68.0, 88.9, 94.5, 122.5, 141.5, 196.0, 224.0, 242.0)
    servo_cradle_width_mm: float = 52.0
    servo_cradle_depth_mm: float = 3.2
    servo_cradle_height_mm: float = 46.0
    servo_track_spacing_mm: float = 48.0
    servo_track_width_mm: float = 4.0
    servo_track_depth_mm: float = 2.4
    servo_track_length_mm: float = 220.0
    servo_front_pocket_width_mm: float = 30.0
    servo_front_pocket_depth_mm: float = 24.0
    servo_front_pocket_height_mm: float = 238.0
    servo_front_pocket_center_z_mm: float = 132.0
    wire_channel_start_z_mm: float = 78.0
    wire_channel_end_z_mm: float = 222.0
    wire_channel_rib_width_mm: float = 1.0
    wire_channel_lanes: ClassVar[tuple[tuple[str, float, float, float], ...]] = (
        ("splitter_positive_to_servo", -28.0, 4.2, 3.4),
        ("battery_positive_input", -22.8, 4.2, 3.4),
        ("spare_high_current", -17.6, 4.2, 3.4),
        ("pwm_signal", -8.0, 3.0, 2.2),
        ("controller_5v", -4.0, 3.0, 2.2),
        ("controller_ground", 0.0, 3.0, 2.2),
        ("buck_input_positive", 4.0, 3.0, 2.2),
        ("buck_input_ground", 8.0, 3.0, 2.2),
        ("battery_ground_input", 22.8, 4.2, 3.4),
        ("splitter_ground_to_servo", 28.0, 4.2, 3.4),
    )


def box_dict(box: Box) -> dict[str, object]:
    data = asdict(box)
    data.update(
        {
            "min": [round(box.min_x, 2), round(box.min_y, 2), round(box.min_z, 2)],
            "max": [round(box.max_x, 2), round(box.max_y, 2), round(box.max_z, 2)],
        }
    )
    return data


def physical_components() -> list[Box]:
    return [
        Box("battery_2s_5000mah", 0, -9, 40, 43, 22, 75, 0.4),
        Box("xalxmaw_inline_splitter_pair", 0, -4.5, 94.5, 27, 13, 32, 0.4),
        Box("lm2596_buck_current_vertical", 0, -11, 141.5, 40, 10, 60, 0.4),
        Box("controller_breadboard_assembly", 0, -11, 196, 35, 14, 47, 0.4),
        Box("servo_body", 0, 16.8, 88.9, 40.5, 20, 37.5, 0.6, "front_exposed"),
    ]


def physical_components_for_servo_center(center_z_mm: float) -> list[Box]:
    components = physical_components()
    return [
        Box(
            box.name,
            box.x,
            box.y,
            center_z_mm if box.name == "servo_body" else box.z,
            box.width,
            box.depth,
            box.height,
            box.clearance,
            box.kind,
        )
        for box in components
    ]


def layout_features() -> list[Box]:
    return [
        Box("solar_panel_series_pair", 0, 18.7, 140, 60, 3, 220, 1.5, "surface"),
        Box("pill_status_led", 0, 18.9, 253, 22, 3, 5, 1.0, "surface"),
        Box("servo_body", 0, 16.8, 88.9, 40.5, 20, 37.5, 0.6, "front_exposed"),
        Box("servo_vertical_track", 0, 5.3, 132, 52, 3.2, 220, 0.0, "adjustable_track"),
        Box("servo_arm_slot", 0, 16, 132, 30, 24, 238, 0.0, "open_pocket"),
        Box("electronics_service_bay", 0, -7.8, 150, 64, 28, 140, 0.0, "bay"),
        Box("battery_slot", 0, -6.3, 41, 46.5, 25, 80.5, 0.0, "slot"),
    ]


def wire_routing_keepouts(scenario: HousingScenario) -> list[Box]:
    inner_rear_y = -scenario.case_depth_mm / 2 + scenario.wall_mm
    channel_height = scenario.wire_channel_end_z_mm - scenario.wire_channel_start_z_mm
    channel_center_z = (scenario.wire_channel_start_z_mm + scenario.wire_channel_end_z_mm) / 2
    return [
        Box(
            f"wire_channel_{name}",
            x,
            inner_rear_y + rib_depth / 2,
            channel_center_z,
            clear_width + scenario.wire_channel_rib_width_mm * 2,
            rib_depth,
            channel_height,
            0.0,
            "wire_routing",
        )
        for name, x, clear_width, rib_depth in scenario.wire_channel_lanes
    ]


def collision_pairs(boxes: list[Box]) -> list[list[str]]:
    pairs: list[list[str]] = []
    for index, first in enumerate(boxes):
        for second in boxes[index + 1 :]:
            if first.intersects(second):
                pairs.append([first.name, second.name])
    return pairs


def cross_collision_pairs(first_boxes: list[Box], second_boxes: list[Box]) -> list[list[str]]:
    return [
        [first.name, second.name]
        for first in first_boxes
        for second in second_boxes
        if first.intersects(second)
    ]


def containment(box: Box, inner_width: float, inner_depth: float) -> dict[str, object]:
    expanded = box.expanded()
    half_width = inner_width / 2
    half_depth = inner_depth / 2
    side_margin = min(expanded.min_x + half_width, half_width - expanded.max_x)
    rear_depth_margin = expanded.min_y + half_depth
    depth_margin = (
        rear_depth_margin
        if box.kind == "front_exposed"
        else min(rear_depth_margin, half_depth - expanded.max_y)
    )
    return {
        "name": box.name,
        "expanded_width_mm": round(expanded.width, 2),
        "expanded_depth_mm": round(expanded.depth, 2),
        "side_margin_mm": round(side_margin, 2),
        "depth_margin_mm": round(depth_margin, 2),
        "fits_width": side_margin >= 0,
        "fits_depth": depth_margin >= 0,
        "front_protrusion_allowed": box.kind == "front_exposed",
    }


def run_simulation(scenario: HousingScenario) -> dict[str, object]:
    components = physical_components()
    expanded_components = [box.expanded() for box in components]
    features = layout_features()
    wire_channels = wire_routing_keepouts(scenario)

    inner_width = scenario.case_width_mm - scenario.wall_mm * 2
    inner_depth = scenario.case_depth_mm - scenario.wall_mm * 2
    component_fit = [containment(box, inner_width, inner_depth) for box in components]
    wire_channel_fit = [containment(box, inner_width, inner_depth) for box in wire_channels]
    wire_channel_collisions = cross_collision_pairs(wire_channels, expanded_components)
    worst_side = min(item["side_margin_mm"] for item in component_fit)
    worst_depth = min(item["depth_margin_mm"] for item in component_fit)
    expanded_servo = next(box.expanded() for box in components if box.name == "servo_body")
    expanded_rear_components = [
        box.expanded() for box in components if box.name != "servo_body"
    ]
    front_plane_clearance = expanded_servo.min_y - max(box.max_y for box in expanded_rear_components)

    top_feature_z = max(box.max_z for box in features)
    bottom_feature_z = min(box.min_z for box in features)
    minimum_housing_height = max(
        top_feature_z + scenario.housing_top_margin_mm,
        scenario.case_height_mm if bottom_feature_z < scenario.housing_bottom_margin_mm else 0,
    )
    vertical_used_height = top_feature_z - bottom_feature_z

    minimum_plate_height = max(
        scenario.mount_rail_length_mm,
        scenario.mount_channel_length_mm,
    ) + scenario.rail_end_margin_target_mm * 2
    rail_end_margin = (scenario.plate_height_mm - scenario.mount_rail_length_mm) / 2
    channel_end_margin = (scenario.plate_height_mm - scenario.mount_channel_length_mm) / 2
    recommended_plate_height = scenario.plate_max_height_mm

    max_width_usage = max(box.expanded().width for box in components) / inner_width
    max_depth_usage = max(box.expanded().depth for box in components) / inner_depth
    vertical_usage = vertical_used_height / scenario.case_height_mm
    servo_adjustment_checks = []
    for center_z in scenario.servo_center_z_samples_mm:
        offset_components = physical_components_for_servo_center(center_z)
        offset_expanded = [box.expanded() for box in offset_components]
        servo_adjustment_checks.append({
            "servo_center_z_mm": center_z,
            "raw_component_collisions": collision_pairs(offset_components),
            "clearance_envelope_collisions": collision_pairs(offset_expanded),
        })

    return {
        "inputs": asdict(scenario),
        "housing": {
            "outer_dimensions_mm": [
                scenario.case_width_mm,
                scenario.case_depth_mm,
                scenario.case_height_mm,
            ],
            "inner_width_mm": round(inner_width, 2),
            "inner_depth_mm": round(inner_depth, 2),
            "p1s_height_margin_mm": round(scenario.p1s_build_height_mm - scenario.case_height_mm, 2),
            "minimum_height_for_current_layout_mm": round(minimum_housing_height, 2),
            "current_height_is_tight_minimum": abs(minimum_housing_height - scenario.case_height_mm) < 0.01,
            "vertical_used_span_mm": round(vertical_used_height, 2),
            "vertical_utilization_percent": round(vertical_usage * 100, 1),
            "max_width_utilization_percent": round(max_width_usage * 100, 1),
            "max_depth_utilization_percent": round(max_depth_usage * 100, 1),
            "worst_side_margin_mm": round(worst_side, 2),
            "worst_depth_margin_mm": round(worst_depth, 2),
            "front_servo_plane_clearance_mm": round(front_plane_clearance, 2),
            "recommendation": "Use the 72 x 56 x 264mm housing to retain the earlier rear electronics stack while giving the servo a continuous, depth-separated front adjustment plane. Print the long parts flat and diagonally on the P1S bed.",
        },
        "plate_height": {
            "housing_height_mm": scenario.case_height_mm,
            "current_plate_height_mm": scenario.plate_height_mm,
            "plate_height_over_housing_mm": round(scenario.plate_height_mm - scenario.case_height_mm, 2),
            "minimum_plate_height_for_open_ended_rails_mm": round(minimum_plate_height, 2),
            "current_extra_above_minimum_mm": round(scenario.plate_height_mm - minimum_plate_height, 2),
            "recommended_plate_height_mm": recommended_plate_height,
            "rail_end_margin_mm": round(rail_end_margin, 2),
            "channel_end_margin_mm": round(channel_end_margin, 2),
            "fits_flush_enclosure_height": scenario.plate_height_mm == scenario.case_height_mm,
            "recommendation": "Use the flush 264mm plate with open-ended rails and a hidden detent. It hides behind the enclosure and still leaves at least 9mm channel end margin.",
        },
        "components": {
            "collision_pairs_raw": collision_pairs(components),
            "collision_pairs_with_clearance": collision_pairs(expanded_components),
            "fit_margins": component_fit,
            "boxes": [box_dict(box) for box in components],
            "features": [box_dict(box) for box in features],
        },
        "wire_routing": {
            "type": "symmetric raised-lip cable-comb raceway on the inside rear wall",
            "z_range_mm": [scenario.wire_channel_start_z_mm, scenario.wire_channel_end_z_mm],
            "lane_count": len(scenario.wire_channel_lanes),
            "active_lane_count": 9,
            "spare_lane_count": 1,
            "outer_edge_margin_mm": 1.7,
            "component_clearance_collisions": wire_channel_collisions,
            "fit_margins": wire_channel_fit,
            "boxes": [box_dict(box) for box in wire_channels],
            "recommendation": "Keep positive high-current routing on the outer left, ground high-current routing on the outer right, and the five low-current paths centered. Leave the third left-side 16 AWG groove unused for the future high-side servo switch, and print a channel-and-retainer coupon with the purchased silicone wire before printing the enclosure.",
        },
        "servo_height_adjustment": {
            "type": "continuously adjustable clamped carriage on dual vertical rails",
            "default_center_z_mm": scenario.servo_default_center_z_mm,
            "servo_center_z_range_mm": list(scenario.servo_center_z_range_mm),
            "track_dimensions_mm": [
                scenario.servo_track_spacing_mm,
                scenario.servo_track_width_mm,
                scenario.servo_track_depth_mm,
                scenario.servo_track_length_mm,
            ],
            "cradle_dimensions_mm": [
                scenario.servo_cradle_width_mm,
                scenario.servo_cradle_depth_mm,
                scenario.servo_cradle_height_mm,
            ],
            "servo_front_exposure_pocket_dimensions_mm": [
                scenario.servo_front_pocket_width_mm,
                scenario.servo_front_pocket_depth_mm,
                scenario.servo_front_pocket_height_mm,
            ],
            "servo_front_exposure_pocket_center_z_mm": scenario.servo_front_pocket_center_z_mm,
            "collision_checks_across_travel": servo_adjustment_checks,
            "recommendation": "Use two rigid rails and a positively clamped carriage. The 22-242mm center range covers nearly the full enclosure while preserving end clearance for the 37.5mm servo body.",
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", action="store_true", help="Print JSON instead of a compact text report.")
    parser.add_argument("--out", type=Path, help="Optional JSON output path.")
    args = parser.parse_args()

    result = run_simulation(HousingScenario())
    if args.out:
        args.out.write_text(json.dumps(result, indent=2) + "\n")

    if args.json:
        print(json.dumps(result, indent=2))
        return 0

    housing = result["housing"]
    plate = result["plate_height"]
    components = result["components"]
    servo_adjustment = result["servo_height_adjustment"]
    wire_routing = result["wire_routing"]
    print("Door Unlocker housing fit simulation")
    print(f"- Housing: {housing['outer_dimensions_mm']} mm")
    print(f"- Minimum housing height for current layout: {housing['minimum_height_for_current_layout_mm']} mm")
    print(f"- Current housing is tight minimum: {housing['current_height_is_tight_minimum']}")
    print(f"- Vertical utilization: {housing['vertical_utilization_percent']}%")
    print(f"- Max width/depth utilization: {housing['max_width_utilization_percent']}% / {housing['max_depth_utilization_percent']}%")
    print(f"- Worst side/depth margin: {housing['worst_side_margin_mm']} mm / {housing['worst_depth_margin_mm']} mm")
    print(f"- Raw component collisions: {components['collision_pairs_raw']}")
    print(f"- Clearance-envelope collisions: {components['collision_pairs_with_clearance']}")
    print(f"- Wire-channel/component collisions: {wire_routing['component_clearance_collisions']}")
    print(f"- Servo center travel: {servo_adjustment['servo_center_z_range_mm']} mm")
    print(f"- Rear-to-servo clearance-envelope separation: {housing['front_servo_plane_clearance_mm']} mm")
    print(f"- Minimum plate height for open-ended rails: {plate['minimum_plate_height_for_open_ended_rails_mm']} mm")
    print(f"- Current plate extra above minimum: {plate['current_extra_above_minimum_mm']} mm")
    print(f"- Recommendation: {plate['recommendation']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
