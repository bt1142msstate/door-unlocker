# Mount Force Simulation

This is a first-order mechanical check for the removable Door Unlocker mount. It is not a certified structural analysis and does not replace physical testing on the real door, real paint, real Command strips, and real printed material.

## Verdict

**Status: Conditional pass - good to continue prototype fit testing, not yet cleared for unattended door mounting.**

The current three-part mount concept is good to keep prototyping because the PLA rails,
dovetail capture, backplate geometry, and four X-Large Command strip layout pass this
simplified fit/strength check. The weak point is not the printed rail system; it is the
adhesive margin against a full servo-stall load.

**Good to go for now:** print coupons, test the dovetail fit, bench-test the housing, and mock the plate on a safe test surface.

**Not good to go yet:** trusting it on the real door unattended. Four X-Large Command strip
pairs fit the 2 in x 264 mm plate, but they provide only about **1.28x** ideal static margin
against full servo stall plus estimated assembly weight. The preferred **3x** stall margin
would require **10 pairs**, which do not fit this narrow hidden plate.

Before real door use, measure the actual handle force. If the handle force is over about
**4.9 lbf**, this plate does not meet the preferred 3x margin. If it is over about
**8.2 lbf**, it does not meet a 2x margin. In that case, use a non-damaging bracket,
reduce the required servo force/angle, add a compliant force limiter, or move to the
handle-attached bracket concept.

| Check | Result | Notes |
| --- | --- | --- |
| PLA dovetail rails | Pass | Rail shear stress is far below the conservative PLA allowance in this simplified model. |
| Backplate bending | Pass | Calculated bending margin is acceptable for prototype testing, but physical creep testing is still required. |
| Four X-Large strip fit | Pass | Four pairs fit as two columns by two rows on the 2 in x 264 mm plate. |
| Adhesive vs full servo stall at 3x margin | Fail | The current plate fits 4 pairs; the 3x stall target needs 10 pairs. |
| Overall mount readiness | Conditional pass | Continue prototyping, but do not treat it as door-ready until measured handle-force and load tests pass. |

## Source Assumptions

- Command 20 lb X-Large Picture Hanging Strips: 3M lists four X-Large pairs as holding 20 lb on suitable smooth surfaces. That is treated as an ideal static picture-hanging capacity of 5 lb per pair.
- Command 17217 X-Large strip footprint: 4 3/8 x 7/8 x 1/16 in, or about **111.1 x 22.2 x 1.6 mm**, used for plate fit planning and the 3D concept.
- Smaller Command picture-hanging strips were checked against the same 2 in x 264 mm flush plate. Large 17206 strips fit more loosely but give less ideal capacity, while Medium 17204 strips can fit more pairs but still do not beat the four X-Large pairs on total ideal capacity.
- INJORA 35 kg servo: listing torque is 35 kg-cm at 8.4 V.
- Servo arm: 56 mm metal horn.
- Current adhesive plate constraint: 2 in wide by 264 mm tall, or 50.8 x 264 mm, sized to hide behind the enclosure while still fitting four vertical X-Large pairs as two rows of two.
- Estimated full door-supported assembly weight: **1.8 lbf** rounded up from the
  solar and servo-switch-equipped Phase 2 mass budget. That includes the hidden mounting plate, Command
  strips, enclosure, battery, servo, controller, inline splitters, buck, wiring, service cover,
  two mini solar panels, solar charger allowance, battery monitor allowance, and servo
  power switch allowance.
- Dovetail rail profile: 60 degree face, 8 mm neck, 5.5 mm depth, 14.3509 mm computed head, and 0.40 mm per-side channel clearance. Solid rails are 244 mm long and open-ended, with a hidden detent for retention.
- Print target: Bambu Lab PLA Pure on a Bambu Lab P1S with the included 0.4 mm nozzle.
- Conservative printed-part strength: Bambu PLA Pure Z-direction tensile strength is treated as 30 MPa; this is the layer-adhesion-sensitive value.

Sources:

- Command official product page: https://www.command.com/3M/en_US/p/d/b5005604179/
- Command application guidance: https://www.command.com/3M/en_US/command/how-to-use/picture-hanging-strips/
- Uline 3M 17217 dimensions table: https://www.uline.com/Product/Detail/S-26009/3M-Command/3M-17217-Command-Picture-Hanging-Strips-Extra-Large
- INJORA servo listing: https://www.amazon.com/dp/B0B56SN46D
- Bambu PLA Pure technical data sheet: https://store.bblcdn.com/s7/default/ecb663b46ebb4fb984786d33befb8d2f/PLA_Pure_TDS.pdf
- Bambu P1S product/spec page: https://us.store.bambulab.com/products/p1s

## Servo Stall Load

The worst-case actuator force is estimated from servo stall torque:

```text
torque = 35 kg-cm x 9.80665 N/kgf x 0.01 m/cm
torque = 3.4323 N-m

tip force = torque / arm length
tip force = 3.4323 / 0.056
tip force = 61.29 N = 13.78 lbf
```

That is a conservative stall estimate. The real handle force should be measured with a luggage scale or fish scale because the door handle probably needs less force than the servo can produce.

## Command Strip Count

Using the manufacturer static rating as an ideal shear capacity:

```text
ideal capacity per pair = 20 lb / 4 pairs = 5 lb per pair
stall demand with 1.8 lb assembly weight = 15.58 lb
3x servo-stall safety target = 46.74 lb
pairs needed for servo-stall 3x = ceil(46.74 / 5) = 10 pairs

2 in x 264 mm plate fit = 2 columns x 2 rows = 4 pairs
max ideal static capacity = 4 x 5 lb = 20 lb
static safety factor against servo stall + 1.8 lb assembly = 20 / 15.58 = 1.28x
```

The constrained 2 in x 264 mm flush plate can fit **4 X-Large pairs maximum**. The fit is tight but valid:

```text
X-Large strip pair = 111.1 H x 22.2 W x 1.6 D mm
two-column width = 22.2 + 4.0 gap + 22.2 = 48.4 mm
side margin on 50.8 mm plate = (50.8 - 48.4) / 2 = 1.2 mm

modeled row centers = +/-57.6 mm from plate center
top/bottom margin = (264.0 - (115.1 + 111.1)) / 2 = 18.9 mm
gap between rows = 115.1 - 111.1 = 4.0 mm
```

That is the optimal count for the current size limit because using fewer X-Large pairs only gives up margin, and more X-Large pairs do not physically fit without changing the plate width, strip orientation, or strip type. Add shallow printed placement outlines or use an installation jig because the side margin is only about **1.2 mm**.

### Strip Size Comparison

```text
17217 X-Large: 4 pairs fit, 20 lb ideal total capacity. Selected.
17206 Large:   4 pairs fit, 15 lb ideal total capacity. Looser side fit, less capacity.
17204 Medium:  6 pairs fit, 15 lb ideal total capacity. More pieces, still less capacity.
```

So the X-Large 17217 strips do fit and are still the best Command-strip choice for the current 2 in x 264 mm flush backplate.

Four pairs do **not** meet a 3x margin against full servo stall. They can work only if the real measured handle force is low enough:

```text
with 4 pairs and 1.8 lb assembly weight:
max handle force for 1.5x margin = 11.53 lbf
max handle force for 2.0x margin = 8.20 lbf
max handle force for 3.0x margin = 4.87 lbf
max handle force for 4.0x margin = 3.20 lbf
```

Recommendation: use all **4 X-Large pairs** on this narrow plate, then measure the actual
door-handle force. If the handle force is over about **4.9 lbf**, the four-pair plate does
not meet the preferred 3x target. If it is over about **8.2 lbf**, it does not even meet a
2x target. In either case, add a non-damaging bracket, reduce the required handle force,
add a compliant force limiter, or use a different adhesive/mounting strategy.

## Dovetail Fit Check

The rail is mathematically captured:

```text
head width = neck + 2 x depth / tan(60deg)
head width = 8 + 2 x 5.5 / tan(60deg)
head width = 14.3509 mm

channel neck = 8 + 2 x 0.40 = 8.80 mm
channel depth = 5.5 + 0.40 = 5.90 mm
channel head = 15.6127 mm
capture overlap each side = (14.3509 - 8.80) / 2 = 2.7754 mm
```

The enclosure can slide along the rails because the channel is larger than the rail. It cannot pull straight off the plate because the rail head is wider than the channel neck.

The solid rail span now runs from 10.0 mm to 254.0 mm on the 264 mm housing reference, leaving **10.0 mm** of end margin at both ends. The housing channel preview is 246 mm long, leaving **9.0 mm** of end margin at both ends.

At servo stall, the simple two-rail neck shear stress is only about 0.0157 MPa, so the rails are not the expected limiting part in this model. Print orientation, layer adhesion, hidden-detent geometry, and local stress around screw/servo bosses still need physical test prints.

## Bambu PLA Pure Printed-Part Check

This is still a first-order estimate, but it keeps the housing grounded in the actual prototype material instead of generic PLA assumptions.

```text
Bambu PLA Pure Z tensile strength = 30 MPa
Design allowable with 4x printed-part margin = 7.5 MPa

two-rail neck shear stress = 61.29 N / (2 x 8 mm x 244 mm)
two-rail neck shear stress = 0.0157 MPa
rail safety vs Z tensile = 1910.9x

plate bending moment = 61.29 N x 45 mm = 2758 N-mm
50.8 x 7 mm plate simple bending stress = 6.65 MPa
simple plate-tip deflection = 0.58 mm
plate safety vs Z tensile = 4.5x

hidden detent = retention feature only, not primary load-bearing structure
```

Interpretation: the PLA rails are comfortably above the calculated servo stall load. The back plate is acceptable in this simplified check, but it is closer to the design margin because the servo force creates an out-of-plane moment. The hidden detent should retain the sled against accidental sliding; it should not be treated as the primary load path. The actual limiting risks are likely Command-strip peel, paint adhesion, PLA creep over time, and heat. Bambu lists PLA Pure heat deflection at about 56 C under 1.8 MPa, so do not treat this as proven for direct sun or hot-door conditions until it is physically tested.

## P1S Tight-Fit Housing Assumptions

- Main enclosure envelope: **72 W x 34 D x 264 H mm**. It exceeds one P1S axis by 8 mm but fits flat when rotated diagonally on the 256 x 256 mm bed.
- Door plate: **50.8 W x 7 D x 264 H mm**, matching the enclosure height so the mount is mostly hidden once installed; print it flat and diagonally.
- Removable service cover: **66 W x 2.2 D x 252 H mm**, a near full-height maintenance face that fits directly within one P1S axis.
- Print note: confirm the slicer's skirt, purge-line, and toolhead-clearance envelope before starting either diagonal long-part print.
- Dovetail channel clearance: **0.40 mm per side** as the tight default. Print coupons at 0.30, 0.40, 0.50, and 0.60 mm before printing the full plate.
- Dovetail rail spacing: **30 mm center-to-center**, narrowed so the dual captive rails fit on the 2 in plate. Solid rail length is **244 mm**, and the housing channel preview is **246 mm**, leaving 10 mm and 9 mm end margins respectively.
- Hard component clearance: about **0.6 mm per side** for servo/controller/buck fit surfaces.
- Servo height adjustment: use a removable **42 W x 23 D x 3 H mm** cradle on **6 W x 20 D x 2.2 H mm** left/right notch ledges at **-5 / 0 / +5 mm** from the default servo height, so the servo can be aligned to the handle while still being tightly supported from the sides.
- Battery clearance: about **1.5 mm per side**. The battery should be retained but not compressed.
- Solar skin: two **6V/1W, 110 x 60 mm** mini panels are now the selected Phase 2 test direction. They should be treated as a thin outer front/service-cover skin and routed into a proper 2S lithium solar charger, not directly to the pack.
- Battery percentage: use a switched high-value divider into the XIAO ADC for the low-power prototype, then move to a MAX17263-class multi-cell gauge when accurate SOC/current/time estimates are worth the extra board complexity.
- Servo power cut: add a controller-driven load switch so servo positive is physically disconnected when locked. Software detach alone does not guarantee lowest idle power because the servo electronics may still draw current while powered.

## Physical Test Plan

1. Print a small dovetail rail test coupon before printing the full plate. Test 0.30, 0.40, 0.50, and 0.60 mm per-side clearance; use the smallest one that slides smoothly without rattle.
2. Measure the real door-handle force with a luggage scale or fish scale. Pull down at the point where the servo cap will contact the handle.
3. Mount a scrap plate with the planned strip count on a safe painted test surface. Let the strips dwell per Command instructions before loading.
4. Print the plate and housing in Bambu PLA Pure with the rails oriented in the XY plane where possible, then inspect rail layer adhesion and channel finish.
5. Hang a static load equal to at least 2x the measured handle force for 30 minutes.
6. Cycle the servo motion at least 100 times while watching for plate creep, rail looseness, paint lifting, strip peel, detent wear, or PLA cracking.
7. If the plate creeps or peels, increase plate area, add pairs, reduce servo push force/angle, add a non-damaging mechanical bracket, or move to the Phase 3 handle-attached bracket.

## Run The Calculator

```bash
./script/mount_force_sim.py
./script/mount_force_sim.py --json --out docs/mount-force-simulation-last-run.json
```
