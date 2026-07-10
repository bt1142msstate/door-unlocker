# Optimal Component List

This list separates the current desk-test/prototype hardware from the parts we should bias toward when the design starts optimizing for power, size, serviceability, and a cleaner enclosure. The goal is not to buy every item immediately. The goal is to make clear what the best direction is when replacing bulky prototype modules with a purpose-built power and control stack.

## Selection Rules

- Prefer one main 2S battery unless testing proves a separate controller battery is worth the added charging and service complexity.
- Physically cut servo power when locked; software-only PWM detach is not the lowest-power final state.
- Keep servo ground, controller ground, and battery ground common. Switch the servo positive rail with a true high-side switch.
- Replace the LM2596 module with a low-quiescent regulator before judging final battery life.
- Use protected solar charging. Solar panels should never connect directly to the 2S lithium pack.
- Use switched battery measurement for the prototype, then a real multi-cell fuel gauge when the PCB is mature.
- Keep connectors serviceable where they help battery swaps, servo replacement, and field repair.

## Power-Optimized Electrical Stack

| Subsystem | Current Prototype | Optimal Direction | Why | Source |
|---|---|---|---|---|
| BLE controller | Seeed Studio XIAO nRF52840 Sense | Keep XIAO for Phase 1/2; later use a custom nRF52840/nRF52 module board | BLE is already fast and secure. The big power win is removing board overhead, LEDs, unused sensors, and bulky wiring later. | [Seeed XIAO BLE docs](https://wiki.seeedstudio.com/XIAO_BLE/), [Nordic BLE family](https://www.nordicsemi.com/Products/Wireless/Bluetooth-Low-Energy) |
| Controller regulator for 2S pack | LM2596 adjustable buck | TI TPS62177-class 2S-capable low-IQ buck for the controller rail | Works directly from a 2S pack voltage range and is dramatically better for standby than a large LM2596 board. | [TI TPS62177 datasheet](https://www.ti.com/lit/ds/symlink/tps62177.pdf) |
| Higher-current regulated rail | LM2596 if needed | TI TPS62933-class low-IQ 3A buck only if later sensors/cameras need more current | Good fit for future accessory rails; not necessary for the minimal controller-only rail. | [TI TPS62933](https://www.ti.com/product/TPS62933) |
| Ultra-low-power 1S option | Not used | TI TPS62840-class 60 nA buck only if the architecture ever moves to a 1S controller rail | Extremely low quiescent current, but its input limit makes it a bad direct fit for the current 2S pack. | [TI TPS62840](https://www.ti.com/product/TPS62840) |
| Servo power cutoff | Prototype MOSFET module | True high-side servo rail switch; prototype with Pololu Big MOSFET Slide Switch MP or the Amazon MOSFET board, then move to a smart high-side switch/custom MOSFET stage | Servo should be fully unpowered when locked, then powered only while moving or holding unlock pressure. High-side switching avoids ground-reference problems and PWM back-powering. | [Pololu Big MOSFET Slide Switch MP](https://www.pololu.com/product-info-merged/2814), [TI high-side switches](https://www.ti.com/product-category/power-management/high-side-switches-controllers/switches/overview.html), [Infineon high-side switches](https://www.infineon.com/products/power/smart-power-switches/high-side-switches) |
| Solar panel | Amazon 6V/1W panel kit | Two thin 6V-class panels in series; use waterproof/ETFE monocrystalline panels when enclosure quality matters | Two panels in series give a better input range for a 2S solar charger. ETFE/waterproof panels are better for real enclosure testing than generic epoxy panels. | [Voltaic 1.2W 6V ETFE panel](https://voltaicsystems.com/1-watt-6-volt-solar-panel-etfe/), [Adafruit 6V 1W panel](https://www.adafruit.com/product/3809) |
| Solar charging | Not installed yet | BQ24650-class 1-6 cell solar charger with MPPT, configured for 2S lithium | Handles the solar-to-2S battery problem correctly instead of treating the panel like a raw power supply. | [TI BQ24650](https://www.ti.com/product/BQ24650) |
| Battery protection/balancing | Battery pack internal protection, unknown details | Keep using protected packs; for custom packs use a known 2S protector/balancer path | A 2S lithium pack needs overcharge, overdischarge, overcurrent, short-circuit, and balancing protection. | [TI bq2920x 2S protection/balancing](https://www.ti.com/lit/gpn/BQ29200) |
| Battery percentage | Not final | Phase 2: switched high-value resistor divider into XIAO ADC. Production: MAX17263-class multi-cell fuel gauge | The switched divider costs almost no sleep current when disabled. The fuel gauge adds better percentage, time-to-empty, age, and current data when the PCB is ready. | [Analog MAX17263](https://www.analog.com/en/products/max17263.html), [Analog LTC2944](https://www.analog.com/en/products/ltc2944.html) |
| Quick-swap battery contacts | XT30 pigtail | Fixed XT30 dock for Phase 1.5/2; later evaluate high-current spring contacts/pogo contacts only if they are rated with enough margin | XT30 is cheap, proven, and high-current enough. Spring contacts are cleaner but need real current, vibration, and wear validation. | [XT30 reference via DigiKey PDF](https://mm.digikey.com/Volume0/opasdata/d220001/medias/docus/745/FIT0586_Web.pdf), [Mill-Max spring-loaded connectors](https://www.mill-max.com/engineering-notebooks/spring-loaded-pogo-pins-connectors), [Keystone battery contacts](https://www.keyelco.com/category.cfm/Battery-Coin-Cell-Holders-Contacts-Clips/Cylindrical-Cell-Contacts/id/410) |
| Wire harness | Breadboard jumpers, XALXMAW 1-in/2-out splitters, XT30 leads | 16 AWG stranded tinned copper silicone for servo/battery current; 22 AWG stranded tinned copper silicone for control and low-current rails; use the splitters' listed 10mm strip length and pull-test every clamp | Keeps high-current paths low resistance while giving the positive and ground branches cleaner inline cable routing. | [Purchased inline splitters](https://www.amazon.com/dp/B0B28GYYL2), current wiring notes in [Phase 1 HTML](../phase-1-desk-test-wiring.html) |
| Environmental protection | Open prototype | Phase 5/6: gasketed seams, coated PCBs, pressure vent if sealed, flame-retardant material review, and thermal fault handling | Water resistance and heat/fire behavior become product concerns after the removable indoor design is proven. | [MG Chemicals conformal coatings](https://mgchemicals.com/category/conformal-coatings/), [GORE adhesive protective vents](https://www.gore.com/products/protective-adhesive-vents-electronic-outdoor-enclosures), [Bambu PLA Basic TDS](https://wiki.bambulab.com/filament-acc/abs-asa-pc/bambu_pla_basic_technical_data_sheet.pdf) |

## Recommended Phase Path

### Phase 1 / Desk Test

Keep the current XIAO, 2S battery, inline splitter pair, XT30, servo, and breadboard setup. Add the prototype MOSFET switch only after verifying the wiring on the bench. Do not use the solar charger or custom buck board until the desk test is stable.

### Phase 1.5 / Removable Mount

Use the same electronics, but physically package the battery for quick removal. A fixed XT30 dock is the simplest first version: battery slides up into the housing, mates to the dock, and unlatches without flexing the internal wiring.

### Phase 2 / Power-Optimized Enclosure

Replace the bulky LM2596 with a 2S-capable low-IQ buck. Add the servo high-side power switch, switched battery sensing, solar panels, and a protected 2S solar charger. This is the first phase where battery-life math should be remeasured using real current logs.

### Phase 5+ / Product Electronics

Move the inline splitters, buck, load switch, battery monitor, solar charger, protection, and connectors onto a purpose-built board or short harness. At that point the BOM should be scored on sleep current, active current, thickness, connector count, repairability, cost, and safety margin.

## Current Best Bets

- **Best immediate servo cutoff test:** the Amazon MOSFET module already added to the cart, but only after checking whether it switches high-side or low-side.
- **Best cleaner prototype servo cutoff:** Pololu Big MOSFET Slide Switch MP, because it is documented as a high-side MOSFET switch and works from 4.5V to 40V.
- **Best direct 2S controller buck direction:** TPS62177-class regulator.
- **Best future accessory buck direction:** TPS62933-class regulator if later cameras or sensors need more current.
- **Best battery percentage first pass:** switched resistor divider. It is not as accurate as a fuel gauge, but it is simple and draws essentially nothing while off.
- **Best production battery telemetry direction:** MAX17263-class multi-cell fuel gauge once a custom PCB is justified.
- **Best solar charger direction:** BQ24650-class 2S solar charger with MPPT, configured and tested for the exact panel and battery pack.
