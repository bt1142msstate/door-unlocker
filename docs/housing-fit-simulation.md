# Housing Fit Simulation

This check validates the Phase 2 housing as a tight component-packing model. It is still a first-pass fit simulation; verify the real servo, battery, buck board, inline splitters, wiring bends, and printed tolerances with calipers and test prints before trusting it on a door.

## Current Recommendation

- Keep the main enclosure at **72 W x 34 D x 244 H mm** for the current prototype hardware.
- Keep the door mounting plate at **50.8 W x 7 D x 244 H mm** so it hides behind the enclosure.
- Use four **3M Command 17217 X-Large** picture-hanging pairs on the back plate. Each modeled pair is **111.1 x 22.2 x 1.6 mm**.
- The housing height is already the calculated tight minimum for the current vertical layout.
- Use open-ended dovetail rails plus a small hidden detent instead of visible top/bottom stops.
- The selected solar direction is a thin front/service-cover skin: two **6V/1W, 110 x 60 mm** panels wired in series for a 12V-class solar charger input. The panels are surface geometry and must clear the front-exposed servo pocket.
- Add a servo power-cut module to the service bay plan. The prototype board footprint is about **42 x 26 mm**, but final placement should be measured because the electronics bay is already tight.
- Form two open cable-comb banks on the inside rear wall: **five 4.2 mm lanes for estimated 3.0 mm OD 16 AWG power conductors** and **five 3.0 mm lanes for estimated 1.8 mm OD 22 AWG logic/PWM conductors**. Every connection gets its own lane, and the harness stays with the enclosure sled when the service cover is removed.

## Housing Fit Results

```text
outer housing = 72 x 34 x 244 mm
inner width = 72 - 2 x 3.2 = 65.6 mm
inner depth = 34 - 2 x 3.2 = 27.6 mm

minimum housing height for current layout = 244.0 mm
P1S height margin = 256 - 244 = 12.0 mm
vertical used span = 238.25 mm
vertical utilization = 97.6%
max width utilization = 89.3%
max depth utilization = 90.6%
worst side margin = 0.8 mm
worst depth margin = 1.3 mm
raw component collisions = 0
clearance-envelope collisions = 0
wire-channel/component clearance collisions = 0
```

The buck converter remains the width driver and the battery remains the depth driver. The purchased inline splitters reduce connector depth from 17 mm to 13.5 mm, but their 32 mm length leaves only **0.8 mm** lateral clearance in the horizontal service-bay orientation. The design still keeps the **34 mm** housing depth with **1.3 mm** worst-case modeled depth margin.

## Plate Height Results

```text
housing height = 244.0 mm
rail length = 224.0 mm
channel length = 226.0 mm
target rail/channel end margins = 8.0 mm top + 8.0 mm bottom
minimum plate height = 226.0 + 16.0 = 242.0 mm

current plate height = 244.0 mm
current plate over housing = 0.0 mm
current extra above minimum = 2.0 mm
solid rail end margin = 10.0 mm
channel end margin = 9.0 mm
```

That means the flush **2 in x 244 mm** plate works for this version if retention is handled by a low-profile internal detent or thumb-release feature. Do not use fully open rails with no retention at all.

## Adhesive Layout

```text
selected strip = 3M Command 17217 X-Large
single pair footprint = 111.1 H x 22.2 W x 1.6 D mm
plate width = 50.8 mm
two-column width = 22.2 + 4.0 gap + 22.2 = 48.4 mm
side margin = 1.2 mm each side

modeled row centers = +/-57.6 mm from plate center
top/bottom margin = 8.9 mm
gap between rows = 4.0 mm
```

The X-Large strips fit, but the side margin is intentionally tight. Add shallow printed placement outlines or use a simple install jig so the strips land straight.

## Component Layout Changes

The earlier CAD block layout had the buck converter low enough to overlap the battery envelope. The current layout fixes that:

- Battery center: **x 0, y 0, z 42 mm**
- Buck center: **x 0, y 0, z 102.5 mm**, using the verified **57 W x 14 D x 36 H mm** Seloky envelope
- Lower XALXMAW splitter center: **x 14.5, y 3.3, z 135 mm**, modeled **32 W x 13.5 D x 13 H mm**
- Upper XALXMAW splitter center: **x 14.5, y 3.3, z 154 mm**, modeled **32 W x 13.5 D x 13 H mm**
- XIAO center: **x -19, y 0, z 134 mm**
- Servo body center: **x 0, y -1, z 188 mm**
- Servo front exposure pocket: **56 W x 28 D x 58 H mm**, centered around **z 188 mm**
- Servo-height adjustment cradle: **42 W x 23 D x 3 H mm**, with servo center detents at **183, 188, and 193 mm**
- Servo-height notch ledges: **6 W x 20 D x 2.2 H mm** left/right supports for each detent
- Solar skin allowance: **60 W x 3 D x 220 H mm** on the outer/front surface, representing two stacked 110 x 60 mm panels wired in series. This is not an internal solid block; final panel split/placement still needs a print layout that avoids the servo pocket and service-cover seam.
- Servo power switch allowance: one prototype MOSFET switch module, about **42 W x 12 D x 26 H mm** as an enclosure planning envelope. It is included in mass/BOM planning, but the current no-collision fit model should be re-run after measuring the actual board and choosing a vertical service-bay or service-cover mount.
- No-solder inspection geometry: the HTML/SCAD cutaway now includes a standard **35 W x 8.5 D x 47 H mm** vertical 170-point mini breadboard with the XIAO on its front face. It is not yet included in the core zero-collision verdict because the exact board, header stand-off, wire bends, and service mounting must be measured together.
- Solar conflict: the lower **110 x 60 x 3 mm** panel fits the front-face envelope, but the second full-size panel overlaps the current servo opening. The 3D model shows that second panel in translucent red until a smaller panel or separate carrier is selected.

This keeps the housing tight without requiring a larger shell for the current prototype parts. The adjustable cradle is intentionally coarse: the servo stays supported by the bay/cradle, and the servo can protrude through the front face while the enclosure walls remain structural.

## Repeatable Wire Routing

The complete service harness uses ten vertical, open-ended lanes from **z 84 to 167 mm** on the inside rear wall. These are raised-lip troughs, not recesses cut into the enclosure, so the full **3.2 mm** rear-wall thickness remains intact.

| Bank | Conductors | Clear lane | Estimated wire OD | Bank width | Bend radius |
|---|---:|---:|---:|---:|---:|
| Logic/PWM, left | 5 x 22 AWG | 3.0 mm | 1.8 mm | 21.0 mm | 6 mm |
| High-current power, right | 5 x 16 AWG | 4.2 mm | 3.0 mm | 27.0 mm | 10 mm |

The shared 1mm ribs make the two banks compact. The left bank spans **x -31.8 to -10.8 mm**, the right bank spans **x 4.8 to 31.8 mm**, and a **15.6 mm center service corridor** remains open. Both outer banks retain **1.0 mm** to the 65.6mm-wide interior boundary.

The ten dedicated paths are:

1. Battery XT30 positive to positive splitter input.
2. Battery XT30 ground to ground splitter input.
3. Positive splitter output to servo power-switch input.
4. Servo power-switch output to servo positive.
5. Ground splitter output to servo ground.
6. Positive splitter output to buck IN+.
7. Ground splitter output to buck IN-.
8. Buck OUT+ to breadboard/XIAO 5V.
9. Buck OUT- to breadboard/XIAO ground.
10. Breadboard/XIAO D2 to servo PWM signal.

The channel keepouts have zero modeled collisions with the clearance-expanded battery, buck, splitters, XIAO, and servo boxes. Open ends provide branch and bend space into adjacent bays. Partial retention nibs let each wire snap in or lift out without threading the full harness through a closed tunnel. The HTML cutaway shows the curved branch runs from the grooves into each component port.

The listed wire diameters are conservative estimates, not vendor-confirmed dimensions for the wire that will be purchased. Print separate five-lane logic and power coupons with the actual Bambu PLA Pure profile and test insertion, removal, grip, and repeated flexing before printing the full enclosure.

## Battery Percentage And Solar Charging

For the prototype, the lowest-idle-power way to estimate battery percentage is a switched high-value resistor divider into the XIAO ADC. A practical starting point is a **1M** top resistor and **330k** bottom resistor, which maps an **8.4V** full 2S pack to about **2.08V** at the ADC. Enable the divider only while measuring, add a small capacitor at the ADC node, and average idle readings because voltage-only state-of-charge is approximate under servo load.

For a production-quality percentage, use a low-power multi-cell fuel gauge such as the **MAX17263** class of part. That adds I2C state-of-charge, age, current, and time estimates, but it is more complex than the divider.

The selected solar panel kit is for energy-harvesting experiments. Two 6V panels should be wired in series and routed into a proper **2S lithium solar charger/BMS**. Do not connect raw solar panel output directly to the 2S battery.

## Servo Power Cut

Software-only servo detach is not enough for the lowest-power design because the servo electronics can still draw idle current whenever its red/black leads remain powered. Phase 2 should add a controller-driven power switch so the servo is physically unpowered in the locked state.

Preferred wiring is a high-side switch:

```text
Battery/positive splitter -> high-side load switch IN
high-side load switch OUT -> servo red
servo ground -> ground splitter/common ground
XIAO GPIO -> switch control input
XIAO D2 -> servo PWM signal
```

When locked, firmware should set the PWM pin low or high-impedance, wait briefly, then cut servo positive. When unlocking or holding the handle down, firmware should enable servo power before command pulses and keep it enabled only while the handle must stay held down.

The Amazon MOSFET module is a prototype test part. Before final wiring, check with a multimeter whether it switches positive or ground. If it is low-side only, use it for bench testing or add signal isolation; otherwise the servo can be partly back-powered through the PWM signal line.

## Run The Calculator

```bash
./script/housing_fit_sim.py
./script/housing_fit_sim.py --json --out docs/housing-fit-simulation-last-run.json
```
