# Door Unlocker Phase 2 CAD

This folder contains the first-pass 3D-print enclosure model for the Door Unlocker.
The current printable target is Bambu Lab PLA Pure on a Bambu Lab P1S with the included 0.4mm nozzle.

Files:

- `phase2-enclosure.scad` - parametric OpenSCAD model with shell, back plate, removable service cover, pockets, and color-coded component blocks.
- `phase2-dimensions.json` - dimension assumptions and clearance values used by the model.

This is a fit model, not a final print-ready product. Before printing a functional version:

- Measure the actual servo body, tabs, cable exit, battery, inline splitters, XIAO headers, and buck converter with calipers.
- Confirm the servo arm swing path against the real door handle geometry.
- Check the slide mount fit: the back plate uses dual captive dovetail rails with a 60 degree face angle, 8mm neck, 14.35mm calculated head width, 5.5mm depth, and 0.40mm per-side clearance channels in the enclosure.
- Use the constrained 2in-wide back plate when testing Command strips. It is flush with the 264mm enclosure and fits four 3M Command 17217 X-Large pairs in two columns by two rows. Each modeled pair is 4 3/8 x 7/8 x 1/16in, or about 111.1 x 22.2 x 1.6mm.
- The X-Large strips fit tightly across the plate: two columns leave about 1.2mm side margin with a 4mm center gap. Large and Medium Command strips were checked, but they reduce total ideal capacity on this plate, so 17217 X-Large remains the selected adhesive.
- The solid dovetail rails are 244mm long and open-ended, leaving 10mm end margin on the flush plate. The housing channel preview is 246mm long, leaving 9mm end margin. Use a small hidden detent or thumb-release feature so the sled does not creep off the rails.
- The housing-fit simulation keeps the main shell at 72 x 34 x 264mm. The reversed current-hardware stack calculates to 259.5mm minimum height, so the selected shell retains about 4.5mm of design headroom, uses 85.4% of the available vertical span, and has no raw, clearance-envelope, or rear wire-channel collisions. The prototype power-switch envelope, branch-wire bends, and second solar panel still require physical layout resolution.
- The 264mm mounting plate is intentionally flush with the enclosure so the door-side mount is mostly hidden after installation.
- Decide whether the large LM2596 buck remains inside Phase 2 or is replaced by a smaller low-quiescent regulator/charger board.
- Use `../docs/optimal-components.md` as the current migration target when replacing prototype power parts. The preferred direction is a 2S-capable low-IQ buck for the controller rail, a true high-side servo switch, protected 2S solar charging, and low-power battery measurement.
- Treat solar charging as a protected charging subsystem: the selected 6V/1W panels are for a two-panel series solar input, and that input must feed a real 2S lithium solar charger/BMS before reaching the battery.
- Add a servo power-cut stage. The prototype Amazon MOSFET module is useful for bench testing, but the final design should use a true high-side load switch or smart high-side switch so servo positive is physically disconnected when locked while common ground remains shared.
- Check overhangs, wall thickness, fastener bosses, strain relief, and battery retention after the fit model is reviewed.

P1S/PLA Pure print assumptions:

- Three printed parts: 50.8 x 7 x 264mm hidden door mounting plate, 72 x 34 x 264mm main enclosure/sled, and 66 x 2.2 x 252mm removable service cover.
- The mounting plate is intentionally the same height as the main enclosure so it is hidden once the sled is installed. It uses open-ended rails plus a small internal detent instead of bulky visible top/bottom stops.
- Print the mounting plate flat on the P1S bed.
- The service cover is now a near full-height removable panel, not a short hatch, and should use shallow slide/dovetail rails so maintenance access does not require removing the whole enclosure from the door plate.
- Component block layout from top to bottom: battery centered at z224, joined XALXMAW splitters at z169.5, purchased Seloky buck at z122.5, and purchased LampVPath breadboard/XIAO assembly at z68. The front-plane servo remains centered at z88.9 to match the measured handle height; depth separation prevents its overlapping height from colliding with the rear electronics. The buck uses the listing-derived 60 x 40 x 10mm envelope and is rotated to an installed 40 W x 10 D x 60 H orientation. The breadboard uses its purchased 35 W x 8.5 D x 47 H orientation.
- The housing uses a front-exposed servo pocket modeled as 56 x 28 x 58mm around z89, so the servo can protrude from the enclosure face while the enclosure walls remain structural.
- Servo height is adjustable with a removable 42 x 23 x 3mm cradle that can sit on 6 x 20 x 2.2mm left/right notch ledges at -5, 0, and +5mm from the default z88.9 servo center. The servo bay still hugs the body from the sides so the adjustment does not make the servo loose.
- Estimated Phase 2 mass budget with solar, no-solder breadboard, and servo-switch hardware: about 390g of
  components inside or attached to the housing, 390g of printed PLA parts, 638g for the
  removable enclosure with components, and 794g for the full door-supported assembly
  including the hidden plate and Command strips. The force simulation rounds the
  installed assembly up to 1.8lb.
- Battery quick-swap plan: the pack drops into short chamfered guides from the top,
  mates with a fixed lower XT30 dock, and is retained by a small thumb latch or
  spring tab. Keep the 16 AWG dock leads fixed to the housing/inline-splitter path so battery swaps
  do not flex the internal wiring.
- Wire-routing plan: two five-lane raised-lip cable combs run from z42 to z190 on the
  inside rear wall so the complete harness stays attached to the enclosure when the
  service cover is removed. The 27mm right bank uses five 4.2mm-clear lanes for estimated
  3.0mm OD 16 AWG power conductors. The 21mm left bank uses five 3.0mm-clear lanes for
  estimated 1.8mm OD 22 AWG logic/PWM conductors. Shared 1mm ribs leave a 15.6mm center
  service corridor. Preserve 10mm/6mm bend space at open exits and print separate power
  and logic snap-fit coupons with the actual silicone wire before the full enclosure.
- Battery percentage plan: prototype with a switched high-value voltage divider into the
  XIAO ADC so the divider draws power only while measuring. A future production board can
  use a MAX17263-class multi-cell fuel gauge for accurate SOC, time-to-empty, age, and
  current data.
- Solar panel plan: the selected Amazon test kit is three 6V/1W panels around
  110 x 60 x 3mm each. Use two in series for a 12V-class, roughly 2W peak input to a 2S
  lithium solar charger. One panel fits below the current servo pocket; the second
  full-size panel intersects the servo opening and is intentionally shown as a red
  conflict envelope until a smaller panel or separate carrier is selected.
- Servo power-cut plan: XIAO enables the load switch before moving the servo, keeps it on
  only while unlocked/holding the handle down, then sets PWM safe/low or high-impedance
  and cuts servo power when locked. Cheap MOSFET boards should be checked with a
  multimeter before final wiring because many switch the low side; the final production
  topology should switch servo positive.
- Bambu PLA Pure source values used in the calculator: 30MPa Z tensile strength, 55MPa Z bending strength, and 2196MPa Z Young's modulus.
- Use 0.40mm dovetail clearance as the tight default, but print rail coupons at 0.30, 0.40, 0.50, and 0.60mm before the full plate.
- Use around 0.6mm per-side clearance for hard component pockets. Use around 1.5mm per-side clearance for the battery so it is retained without being compressed.
- Keep PLA temperature limits in mind. PLA Pure is not the right final material for direct sun or a hot exterior door unless testing proves it does not creep.

OpenSCAD export:

1. Open `phase2-enclosure.scad` in OpenSCAD.
2. Toggle `show_component_blocks` to `false` before exporting a printable shell.
3. Keep `show_back_plate` enabled if printing the plate and shell as a combined fit mockup, or disable it if exporting the shell only.
4. Use `Design > Render`, then `File > Export > Export as STL`.

The colored component blocks are intentionally for preview and fit checking. They should not be exported as part of the printable enclosure.

Calculators:

```bash
./script/mount_force_sim.py
./script/housing_fit_sim.py
./script/check_phase2_html_model.py
python3 script/check_bench_wiring_paths.py
python3 script/check_controller_breadboard_alignment.py
python3 script/check_splitter_card_alignment.py
```

Dimension starting points:

- Seeed Studio XIAO nRF52840 Sense: https://wiki.seeedstudio.com/XIAO_BLE/
- Optimal component direction: ../docs/optimal-components.md
- INJORA 35kg servo listing used for prototype part identity: https://www.amazon.com/dp/B0B56SN46D
- Purchased XALXMAW 1-in/2-out inline splitters: https://www.amazon.com/dp/B0B28GYYL2
- Current 2S battery listing used for prototype part identity: https://www.amazon.com/dp/B0DPX3FXN9
- Current LM2596 buck listing used for prototype part identity: https://www.amazon.com/dp/B0DM946DHG
- Prototype servo MOSFET switch module added for Phase 2 experiments: https://www.amazon.com/Voltage-Control-Switching-Arduino-Connect/dp/B0F6K4LX6Y
- High-side MOSFET switch reference: https://www.pololu.com/product/2810
- Production smart high-side switch reference: https://www.ti.com/product-category/power-management/high-side-switches-controllers/switches/overview.html
- Selected mini solar panel kit for Phase 2 experiments: https://www.amazon.com/Solar-Polysilicon-Charger-Module-System/dp/B08THXDWS1
- MAX17263 multi-cell fuel-gauge reference for future accurate battery percentage: https://www.analog.com/media/en/technical-documentation/data-sheets/max17263.pdf
- LTC2944 multi-cell battery gas-gauge reference considered for comparison: https://www.analog.com/media/en/technical-documentation/data-sheets/2944fa.pdf

Treat these as layout starting points. The printed fit should be based on measured parts, especially the battery, servo tabs, cable exit, and the exact buck converter board.
