# Housing Fit Simulation

This check validates the Phase 2 housing as a tight component-packing model. It is still a first-pass fit simulation; verify the real servo, battery, buck board, inline splitters, wiring bends, and printed tolerances with calipers and test prints before trusting it on a door.

## Current Recommendation

- Use the main enclosure at **72 W x 56 D x 264 H mm**. The added depth preserves the clean rear electronics stack and gives the servo an independent, continuously adjustable front plane.
- Keep the door mounting plate at **50.8 W x 7 D x 264 H mm** so it hides behind the enclosure.
- Use four **3M Command 17217 X-Large** picture-hanging pairs on the back plate. Each modeled pair is **111.1 x 22.2 x 1.6 mm**.
- The housing height is already the calculated tight minimum for the current vertical layout.
- Use open-ended dovetail rails plus a small hidden detent instead of visible top/bottom stops.
- The selected solar direction remains future Phase 2 work. Two **6V/1W, 110 x 60 mm** panels cannot share the current full-height servo slot without a split panel or separate carrier.
- Add a servo power-cut module to the service bay plan. The prototype board footprint is about **42 x 26 mm**, but final placement should be measured because the electronics bay is already tight.
- Form two open cable-comb banks on the inside rear wall: **five 4.2 mm lanes for estimated 3.0 mm OD 16 AWG power conductors** and **five 3.0 mm lanes for estimated 1.8 mm OD 22 AWG logic/PWM conductors**. Every connection gets its own lane, and the harness stays with the enclosure sled when the service cover is removed.

## Housing Fit Results

```text
outer housing = 72 x 56 x 264 mm
inner width = 72 - 2 x 3.2 = 65.6 mm
inner depth = 56 - 2 x 3.2 = 49.6 mm

minimum housing height for current layout = 264.0 mm
P1S single-axis margin = 256 - 264 = -8.0 mm; print flat and diagonally
vertical used span = 254.75 mm
vertical utilization = 96.5%
max width utilization = 66.8%
max rear-component depth utilization = 46.0%
worst side margin = 10.9 mm
worst rear-component depth margin = 4.4 mm
rear-to-servo clearance-envelope separation = 3.8 mm
raw component collisions = 0
clearance-envelope collisions = 0
wire-channel/component clearance collisions = 0
```

The buck converter is the rear-plane width driver and the battery is its depth driver. The purchased inline splitters stand lengthwise as a joined 27 W x 13 D x 32 H mm pair, leaving **10.9 mm** minimum side margin. The independent front servo plane remains **3.8 mm** clear of the clearance-expanded rear components at every sampled servo height.

## Plate Height Results

```text
housing height = 264.0 mm
rail length = 244.0 mm
channel length = 246.0 mm
target rail/channel end margins = 8.0 mm top + 8.0 mm bottom
minimum plate height = 246.0 + 16.0 = 262.0 mm

current plate height = 264.0 mm
current plate over housing = 0.0 mm
current extra above minimum = 2.0 mm
solid rail end margin = 10.0 mm
channel end margin = 9.0 mm
```

That means the flush **2 in x 264 mm** plate works for this version if retention is handled by a low-profile internal detent or thumb-release feature. Do not use fully open rails with no retention at all.

## Adhesive Layout

```text
selected strip = 3M Command 17217 X-Large
single pair footprint = 111.1 H x 22.2 W x 1.6 D mm
plate width = 50.8 mm
two-column width = 22.2 + 4.0 gap + 22.2 = 48.4 mm
side margin = 1.2 mm each side

modeled row centers = +/-57.6 mm from plate center
top/bottom margin = 18.9 mm
gap between rows = 4.0 mm
```

The X-Large strips fit, but the side margin is intentionally tight. Add shallow printed placement outlines or use a simple install jig so the strips land straight.

## Component Layout Changes

The current CAD follows the same bottom-to-top order as the clean bench wiring map:

- Battery center: **x 0, y -9, z 40 mm**
- Joined XALXMAW splitters: centers at **x -6.75 and +6.75, y -4.5, z 94.5 mm**, each oriented **13.5 W x 13 D x 32 H mm**
- Buck center: **x 0, y -11, z 141.5 mm**, rotated vertically to a **40 W x 10 D x 60 H mm** installed envelope.
- Breadboard/XIAO assembly center: **x 0, y -11, z 196 mm**, using the purchased LampVPath B01KKE602W **35 W x 8.5 D x 47 H mm** breadboard envelope.
- Servo body default center: **x 0, y 16.8, z 88.9 mm** on a depth-separated front plane.
- Servo center travel: **z 22 to 242 mm** on two **220mm** vertical rails.
- Servo front exposure slot: **30 W x 24 D x 238 H mm**, centered at **z 132 mm**.
- Servo carriage: **52 W x 3.2 D x 46 H mm**, clamped at the required height rather than limited to fixed detents.
- Solar skin allowance: **60 W x 3 D x 220 H mm** on the outer/front surface, representing two stacked 110 x 60 mm panels wired in series. This is not an internal solid block; final panel split/placement still needs a print layout that avoids the servo pocket and service-cover seam.
- Phase 2 hardware: the external LED, solar skin, charger, and servo power-switch board are intentionally excluded from the Phase 1.5 interactive viewer. Their fit envelopes remain future work.

The rear stack stays in the earlier clean order. Added depth, rather than a flipped stack, lets the servo move through nearly the full enclosure height while the rear electronics and wiring remain fixed and serviceable.

## Repeatable Wire Routing

The complete service harness uses ten vertical, open-ended grooves from **z 80 to 202 mm** on the inside rear wall. These are raised-lip troughs, not recesses cut into the enclosure, so the full **3.2 mm** rear-wall thickness remains intact. A **4 mm rear raceway** keeps the component mounts forward of the retained wires.

| Zone | Conductors | Clear groove | Estimated wire OD | Bend radius |
|---|---:|---:|---:|---:|
| Positive high-current, outer left | 2 active + 1 spare x 16 AWG | 4.2 mm | 3.0 mm | 10 mm |
| Controller and buck, center | 5 x 22 AWG | 3.0 mm | 1.8 mm | 6 mm |
| Ground high-current, outer right | 2 x 16 AWG | 4.2 mm | 3.0 mm | 10 mm |

Adjacent grooves share 1 mm ribs where their pitches meet. The outer ribs stop at **x -31.1 and +31.1 mm**, preserving **1.7 mm** to each side of the 65.6 mm-wide interior boundary.

The ten dedicated paths are:

1. Battery XT30 positive to positive splitter input.
2. Battery XT30 ground to ground splitter input.
3. Positive splitter output directly to servo positive.
4. Ground splitter output to servo ground.
5. Positive splitter output to buck IN+.
6. Ground splitter output to buck IN-.
7. Buck OUT+ to breadboard/XIAO 5V.
8. Buck OUT- to breadboard/XIAO ground.
9. Breadboard/XIAO D2 to servo PWM signal.
10. Reserved 16 AWG groove for the future high-side servo switch.

The channel keepouts have zero modeled collisions with the clearance-expanded battery, buck, splitters, XIAO, and servo boxes. Open ends provide branch and bend space into adjacent bays. Partial retention nibs let each wire snap in or lift out without threading the full harness through a closed tunnel. The HTML cutaway shows the curved branch runs from the grooves into each component port.

Harness colors are red for positive and regulated 5V, black for shared ground distribution, yellow for PWM, and brown for the final servo ground pigtail. The listed wire diameters are conservative estimates, not vendor-confirmed dimensions for the wire that will be purchased. Print routing coupons with the actual Bambu PLA Pure profile and test insertion, removal, grip, and repeated flexing before printing the full enclosure.

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
