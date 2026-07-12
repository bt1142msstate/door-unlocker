#!/usr/bin/env python3
"""First-order mount force calculator for the Door Unlocker prototype."""

from __future__ import annotations

import argparse
import json
import math
from dataclasses import asdict, dataclass
from pathlib import Path


KGF_CM_TO_NM = 9.80665 * 0.01
N_TO_LBF = 0.2248089431
MM_TO_IN = 1 / 25.4


@dataclass(frozen=True)
class MountScenario:
    servo_torque_kg_cm: float = 35.0
    servo_arm_mm: float = 56.0
    command_strip_model: str = "3M Command 17217 X-Large Picture Hanging Strips"
    command_capacity_lb_per_four_pairs: float = 20.0
    safety_factor: float = 3.0
    estimated_assembly_weight_lbf: float = 1.8
    plate_width_mm: float = 2.0 * 25.4
    plate_height_mm: float = 264.0
    current_concept_plate_width_mm: float = 2.0 * 25.4
    current_concept_plate_height_mm: float = 264.0
    strip_length_mm: float = 4.375 * 25.4
    strip_width_mm: float = 0.875 * 25.4
    strip_thickness_mm: float = 0.0625 * 25.4
    strip_gap_mm: float = 4.0
    force_offset_from_door_mm: float = 45.0
    adhesive_row_separation_mm: float = 4.375 * 25.4 + 4.0
    rail_face_angle_deg: float = 60.0
    rail_neck_width_mm: float = 8.0
    rail_depth_mm: float = 5.5
    rail_length_mm: float = 244.0
    rail_channel_length_mm: float = 246.0
    rail_spacing_mm: float = 30.0
    rail_channel_clearance_mm: float = 0.40
    enclosure_height_mm: float = 264.0
    rail_end_margin_target_mm: float = 8.0
    pla_pure_tensile_strength_z_mpa: float = 30.0
    pla_pure_bending_strength_z_mpa: float = 55.0
    pla_pure_youngs_modulus_z_mpa: float = 2196.0
    printed_part_design_safety_factor: float = 4.0
    back_plate_thickness_mm: float = 7.0
    hidden_detent_note: str = "Use a small internal detent or thumb-release feature; do not rely on open-ended rails alone for retention."


def fit_count(width_mm: float, height_mm: float, strip_w_mm: float, strip_l_mm: float, gap_mm: float) -> int:
    columns = math.floor((width_mm + gap_mm) / (strip_w_mm + gap_mm))
    rows = math.floor((height_mm + gap_mm) / (strip_l_mm + gap_mm))
    return max(0, columns) * max(0, rows)


def strip_layout(width_mm: float, height_mm: float, strip_w_mm: float, strip_l_mm: float, gap_mm: float) -> dict[str, object]:
    columns = max(0, math.floor((width_mm + gap_mm) / (strip_w_mm + gap_mm)))
    rows = max(0, math.floor((height_mm + gap_mm) / (strip_l_mm + gap_mm)))
    used_w = columns * strip_w_mm + max(0, columns - 1) * gap_mm
    used_h = rows * strip_l_mm + max(0, rows - 1) * gap_mm
    return {
        "columns": columns,
        "rows": rows,
        "pairs_that_fit": columns * rows,
        "used_width_mm": round(used_w, 2),
        "used_height_mm": round(used_h, 2),
        "side_margin_mm": round((width_mm - used_w) / 2, 2) if columns else 0,
        "top_bottom_margin_mm": round((height_mm - used_h) / 2, 2) if rows else 0,
    }


def dovetail_head_width(neck_mm: float, depth_mm: float, face_angle_deg: float) -> float:
    return neck_mm + 2 * depth_mm / math.tan(math.radians(face_angle_deg))


def run_simulation(scenario: MountScenario) -> dict[str, object]:
    torque_nm = scenario.servo_torque_kg_cm * KGF_CM_TO_NM
    tip_force_n = torque_nm / (scenario.servo_arm_mm / 1000)
    tip_force_lbf = tip_force_n * N_TO_LBF
    per_pair_capacity_lbf = scenario.command_capacity_lb_per_four_pairs / 4
    demand_lbf = tip_force_lbf + scenario.estimated_assembly_weight_lbf
    pairs_for_safety_factor = math.ceil(demand_lbf * scenario.safety_factor / per_pair_capacity_lbf)

    pairs_by_safety_factor = {
        str(factor): math.ceil(demand_lbf * factor / per_pair_capacity_lbf)
        for factor in (1.5, 2.0, 3.0, 4.0)
    }

    offset_in = scenario.force_offset_from_door_mm * MM_TO_IN
    separation_in = scenario.adhesive_row_separation_mm * MM_TO_IN
    peel_couple_lbf = tip_force_lbf * offset_in / separation_in

    current_fit_pairs = fit_count(
        scenario.current_concept_plate_width_mm,
        scenario.current_concept_plate_height_mm,
        scenario.strip_width_mm,
        scenario.strip_length_mm,
        scenario.strip_gap_mm,
    )
    recommended_fit_pairs = fit_count(
        scenario.plate_width_mm,
        scenario.plate_height_mm,
        scenario.strip_width_mm,
        scenario.strip_length_mm,
        scenario.strip_gap_mm,
    )
    selected_layout = strip_layout(
        scenario.plate_width_mm,
        scenario.plate_height_mm,
        scenario.strip_width_mm,
        scenario.strip_length_mm,
        scenario.strip_gap_mm,
    )

    strip_options = [
        {
            "model": "17217 X-Large",
            "length_mm": 4.375 * 25.4,
            "width_mm": 0.875 * 25.4,
            "thickness_mm": 0.0625 * 25.4,
            "capacity_lbf_per_four_pairs": 20.0,
        },
        {
            "model": "17206 Large",
            "length_mm": 3.625 * 25.4,
            "width_mm": 0.75 * 25.4,
            "thickness_mm": 0.0625 * 25.4,
            "capacity_lbf_per_four_pairs": 15.0,
        },
        {
            "model": "17204 Medium",
            "length_mm": 2.75 * 25.4,
            "width_mm": 0.625 * 25.4,
            "thickness_mm": 0.10 * 25.4,
            "capacity_lbf_per_four_pairs": 10.0,
        },
    ]
    strip_option_results = []
    for option in strip_options:
        layout = strip_layout(
            scenario.plate_width_mm,
            scenario.plate_height_mm,
            option["width_mm"],
            option["length_mm"],
            scenario.strip_gap_mm,
        )
        capacity_per_pair = option["capacity_lbf_per_four_pairs"] / 4
        strip_option_results.append({
            "model": option["model"],
            "pair_dimensions_mm": {
                "length": round(option["length_mm"], 2),
                "width": round(option["width_mm"], 2),
                "thickness": round(option["thickness_mm"], 2),
            },
            "capacity_lbf_per_four_pairs": option["capacity_lbf_per_four_pairs"],
            "pairs_that_fit_on_2x11_plate": layout["pairs_that_fit"],
            "ideal_capacity_lbf_on_2x11_plate": round(layout["pairs_that_fit"] * capacity_per_pair, 2),
            "layout": layout,
        })

    rail_head_mm = dovetail_head_width(
        scenario.rail_neck_width_mm,
        scenario.rail_depth_mm,
        scenario.rail_face_angle_deg,
    )
    channel_neck_mm = scenario.rail_neck_width_mm + 2 * scenario.rail_channel_clearance_mm
    channel_depth_mm = scenario.rail_depth_mm + scenario.rail_channel_clearance_mm
    channel_head_mm = dovetail_head_width(
        channel_neck_mm,
        channel_depth_mm,
        scenario.rail_face_angle_deg,
    )
    capture_overlap_each_side_mm = (rail_head_mm - channel_neck_mm) / 2
    rail_total_neck_area_mm2 = 2 * scenario.rail_neck_width_mm * scenario.rail_length_mm
    rail_shear_stress_mpa = tip_force_n / rail_total_neck_area_mm2
    rail_center_z_mm = scenario.enclosure_height_mm / 2
    rail_bottom_z_mm = rail_center_z_mm - scenario.rail_length_mm / 2
    rail_top_z_mm = rail_center_z_mm + scenario.rail_length_mm / 2
    channel_bottom_z_mm = rail_center_z_mm - scenario.rail_channel_length_mm / 2
    channel_top_z_mm = rail_center_z_mm + scenario.rail_channel_length_mm / 2
    rail_bottom_end_margin_mm = rail_bottom_z_mm
    rail_top_end_margin_mm = scenario.enclosure_height_mm - rail_top_z_mm
    channel_bottom_end_margin_mm = channel_bottom_z_mm
    channel_top_end_margin_mm = scenario.enclosure_height_mm - channel_top_z_mm
    printed_allowable_stress_mpa = (
        scenario.pla_pure_tensile_strength_z_mpa / scenario.printed_part_design_safety_factor
    )

    plate_moment_n_mm = tip_force_n * scenario.force_offset_from_door_mm
    plate_second_moment_mm4 = (
        scenario.plate_width_mm * scenario.back_plate_thickness_mm**3 / 12
    )
    plate_bending_stress_mpa = (
        plate_moment_n_mm
        * (scenario.back_plate_thickness_mm / 2)
        / plate_second_moment_mm4
    )
    plate_tip_deflection_mm = (
        tip_force_n
        * scenario.force_offset_from_door_mm**3
        / (
            3
            * scenario.pla_pure_youngs_modulus_z_mpa
            * plate_second_moment_mm4
        )
    )
    max_fit_pairs = recommended_fit_pairs
    static_safety_factor_with_max_fit = max_fit_pairs * per_pair_capacity_lbf / demand_lbf
    allowable_tip_force_by_margin = {
        str(factor): round(max(max_fit_pairs * per_pair_capacity_lbf / factor - scenario.estimated_assembly_weight_lbf, 0), 2)
        for factor in (1.5, 2.0, 3.0, 4.0)
    }
    fits_selected_margin = pairs_for_safety_factor <= max_fit_pairs
    optimal_design_pairs = pairs_for_safety_factor if fits_selected_margin else max_fit_pairs
    plate_height_label = f"{scenario.plate_height_mm:g}"
    practical_recommendation = (
        f"Use {optimal_design_pairs} X-Large pairs on the 2 inch x {plate_height_label} mm flush plate."
        if fits_selected_margin
        else (
            f"The 2 inch x {plate_height_label} mm flush plate fits only {max_fit_pairs} X-Large pairs, "
            f"which is below the {pairs_for_safety_factor} pairs needed for a {scenario.safety_factor:g}x "
            "servo-stall margin. Use all 4 pairs only if measured handle force is low enough, or add a mechanical bracket/force limiter."
        )
    )
    printed_parts_pass = (
        rail_shear_stress_mpa <= printed_allowable_stress_mpa
        and plate_bending_stress_mpa <= printed_allowable_stress_mpa
        and rail_bottom_end_margin_mm >= scenario.rail_end_margin_target_mm
        and rail_top_end_margin_mm >= scenario.rail_end_margin_target_mm
        and channel_bottom_end_margin_mm >= scenario.rail_end_margin_target_mm
        and channel_top_end_margin_mm >= scenario.rail_end_margin_target_mm
    )
    command_strip_fit_pass = recommended_fit_pairs == max_fit_pairs and max_fit_pairs >= 4
    command_strip_stall_margin_pass = fits_selected_margin
    physical_test_required = not command_strip_stall_margin_pass
    verdict_status = "conditional_pass" if printed_parts_pass and command_strip_fit_pass else "fail"
    verdict_label = (
        "CONDITIONAL PASS - okay for prototype fit testing, not cleared for unattended door mounting"
        if verdict_status == "conditional_pass"
        else "FAIL - revise the mount before prototype use"
    )
    verdict_summary = (
        "The PLA rails/backplate and four X-Large strip layout pass this simplified geometry/strength check, "
        "but the adhesive layout does not meet the preferred 3x margin against full servo stall. Measure the real "
        "handle force and run a staged load test before trusting it on a door."
        if verdict_status == "conditional_pass"
        else "At least one core geometry or printed-part check failed. Revise the model and rerun the simulation."
    )

    return {
        "inputs": asdict(scenario),
        "verdict": {
            "status": verdict_status,
            "label": verdict_label,
            "prototype_fit_testing_good_to_go": verdict_status == "conditional_pass",
            "unattended_door_mount_good_to_go": command_strip_stall_margin_pass and not physical_test_required,
            "physical_test_required": physical_test_required,
            "summary": verdict_summary,
            "checks": {
                "printed_parts": "pass" if printed_parts_pass else "fail",
                "command_strip_fit": "pass" if command_strip_fit_pass else "fail",
                "command_strip_full_servo_stall_3x_margin": (
                    "pass" if command_strip_stall_margin_pass else "fail"
                ),
            },
        },
        "servo": {
            "stall_torque_nm": round(torque_nm, 4),
            "tip_force_n": round(tip_force_n, 2),
            "tip_force_lbf": round(tip_force_lbf, 2),
        },
        "command_strips": {
            "selected_model": scenario.command_strip_model,
            "ideal_capacity_lbf_per_pair": round(per_pair_capacity_lbf, 2),
            "ideal_static_capacity_note": "Manufacturer rating is picture-hanging static load; peel/dynamic loads need margin and physical testing.",
            "selected_pair_dimensions_mm": {
                "length": round(scenario.strip_length_mm, 2),
                "width": round(scenario.strip_width_mm, 2),
                "thickness": round(scenario.strip_thickness_mm, 2),
            },
            "selected_2x11_plate_layout_with_4mm_gap": selected_layout,
            "modeled_layout_note": "3D concept places two columns by two rows with centers at +/-13.1mm across and +/-57.6mm vertically, leaving about 1.2mm side margin, 8.9mm top/bottom margin, and 4.0mm between rows.",
            "alternative_strip_fit_comparison": strip_option_results,
            "pairs_by_safety_factor": pairs_by_safety_factor,
            "recommended_design_pairs": optimal_design_pairs,
            "pairs_for_selected_safety_factor": pairs_for_safety_factor,
            "current_concept_plate_pairs_that_fit": current_fit_pairs,
            "recommended_plate_pairs_that_fit": recommended_fit_pairs,
            "fits_selected_safety_factor": fits_selected_margin,
            "static_safety_factor_with_max_fit_pairs": round(static_safety_factor_with_max_fit, 2),
            "max_tip_force_lbf_by_safety_factor_with_max_fit": allowable_tip_force_by_margin,
            "peel_couple_total_lbf_at_top_row": round(peel_couple_lbf, 2),
        },
        "dovetail": {
            "rail_head_width_mm": round(rail_head_mm, 4),
            "channel_neck_width_mm": round(channel_neck_mm, 4),
            "channel_depth_mm": round(channel_depth_mm, 4),
            "channel_head_width_mm": round(channel_head_mm, 4),
            "capture_overlap_each_side_mm": round(capture_overlap_each_side_mm, 4),
            "slides_without_interference": channel_neck_mm > scenario.rail_neck_width_mm and channel_head_mm > rail_head_mm,
            "straight_pull_off_blocked": rail_head_mm > channel_neck_mm,
            "rail_shear_stress_mpa_at_servo_stall": round(rail_shear_stress_mpa, 4),
            "rail_length_mm": round(scenario.rail_length_mm, 2),
            "rail_bottom_z_mm": round(rail_bottom_z_mm, 2),
            "rail_top_z_mm": round(rail_top_z_mm, 2),
            "rail_bottom_end_margin_mm": round(rail_bottom_end_margin_mm, 2),
            "rail_top_end_margin_mm": round(rail_top_end_margin_mm, 2),
            "solid_rail_has_end_margin": (
                rail_bottom_end_margin_mm >= scenario.rail_end_margin_target_mm
                and rail_top_end_margin_mm >= scenario.rail_end_margin_target_mm
            ),
            "channel_length_mm": round(scenario.rail_channel_length_mm, 2),
            "channel_bottom_end_margin_mm": round(channel_bottom_end_margin_mm, 2),
            "channel_top_end_margin_mm": round(channel_top_end_margin_mm, 2),
            "channel_has_end_margin": (
                channel_bottom_end_margin_mm >= scenario.rail_end_margin_target_mm
                and channel_top_end_margin_mm >= scenario.rail_end_margin_target_mm
            ),
            "retention": scenario.hidden_detent_note,
        },
        "printed_pla": {
            "material": "Bambu Lab PLA Pure",
            "printer": "Bambu Lab P1S",
            "assumed_nozzle_mm": 0.4,
            "allowable_stress_mpa_with_4x_margin": round(printed_allowable_stress_mpa, 2),
            "rail_shear_safety_factor_vs_z_tensile": round(
                scenario.pla_pure_tensile_strength_z_mpa / rail_shear_stress_mpa,
                1,
            ),
            "rail_shear_safety_factor_vs_design_allowable": round(
                printed_allowable_stress_mpa / rail_shear_stress_mpa,
                1,
            ),
            "back_plate_bending_stress_mpa": round(plate_bending_stress_mpa, 2),
            "back_plate_bending_safety_factor_vs_z_tensile": round(
                scenario.pla_pure_tensile_strength_z_mpa / plate_bending_stress_mpa,
                1,
            ),
            "back_plate_bending_safety_factor_vs_z_bending": round(
                scenario.pla_pure_bending_strength_z_mpa / plate_bending_stress_mpa,
                1,
            ),
            "back_plate_simple_tip_deflection_mm": round(plate_tip_deflection_mm, 2),
            "thermal_warning": "PLA Pure heat-deflection temperature is about 56C at 1.8MPa; avoid direct sun/hot-door creep testing before trusting the mount.",
        },
        "recommendation": {
            "minimum_for_stall_with_3x_margin": pairs_for_safety_factor,
            "practical_recommendation": practical_recommendation,
            "critical_warning": "Do not trust this as certification. Command strips are not specified for repeated actuator torque or peel loading; do a staged physical load test before door use.",
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", action="store_true", help="Print JSON instead of a compact text report.")
    parser.add_argument("--out", type=Path, help="Optional JSON output path.")
    args = parser.parse_args()

    result = run_simulation(MountScenario())
    if args.out:
        args.out.write_text(json.dumps(result, indent=2) + "\n")

    if args.json:
        print(json.dumps(result, indent=2))
        return 0

    servo = result["servo"]
    strips = result["command_strips"]
    dovetail = result["dovetail"]
    printed_pla = result["printed_pla"]
    recommendation = result["recommendation"]
    verdict = result["verdict"]
    print("Door Unlocker mount force simulation")
    print(f"- Verdict: {verdict['label']}")
    print(f"- Prototype fit testing good to go: {verdict['prototype_fit_testing_good_to_go']}")
    print(f"- Unattended door mount good to go: {verdict['unattended_door_mount_good_to_go']}")
    print(f"- Servo stall tip force: {servo['tip_force_lbf']} lbf ({servo['tip_force_n']} N)")
    print(f"- Command ideal capacity per pair: {strips['ideal_capacity_lbf_per_pair']} lbf")
    print(f"- Pairs needed at 3x margin: {recommendation['minimum_for_stall_with_3x_margin']}")
    print(f"- Recommended design pairs: {strips['recommended_design_pairs']}")
    plate_height_label = f"{MountScenario().plate_height_mm:g}"
    print(f"- Current 2 in x {plate_height_label} mm plate fit count: {strips['current_concept_plate_pairs_that_fit']}")
    print(f"- Recommended 2 in x {plate_height_label} mm plate fit count: {strips['recommended_plate_pairs_that_fit']}")
    dims = strips["selected_pair_dimensions_mm"]
    print(f"- Selected strip: {strips['selected_model']} ({dims['length']} x {dims['width']} x {dims['thickness']} mm)")
    print(f"- Fits 3x servo-stall strip target: {strips['fits_selected_safety_factor']}")
    print(f"- Static safety factor with max fit pairs: {strips['static_safety_factor_with_max_fit_pairs']}x")
    print(f"- Dovetail capture overlap per side: {dovetail['capture_overlap_each_side_mm']} mm")
    print(f"- Dovetail slides: {dovetail['slides_without_interference']}; pull-off blocked: {dovetail['straight_pull_off_blocked']}")
    print(
        "- Rail end margins: "
        f"bottom {dovetail['rail_bottom_end_margin_mm']} mm, "
        f"top {dovetail['rail_top_end_margin_mm']} mm, "
        f"has margin: {dovetail['solid_rail_has_end_margin']}"
    )
    print(f"- Rail shear stress at servo stall: {dovetail['rail_shear_stress_mpa_at_servo_stall']} MPa")
    print(f"- PLA rail shear safety vs Z tensile: {printed_pla['rail_shear_safety_factor_vs_z_tensile']}x")
    print(f"- PLA back-plate bending stress: {printed_pla['back_plate_bending_stress_mpa']} MPa")
    print(f"- PLA simple back-plate deflection: {printed_pla['back_plate_simple_tip_deflection_mm']} mm")
    print(f"- Recommendation: {recommendation['practical_recommendation']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
