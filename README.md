# Door Unlocker

Open-source desk-test prototype for a BLE-controlled servo actuator. The project uses a Seeed Studio XIAO nRF52840 Sense to drive a high-torque servo, plus a SwiftUI iPhone app with Lock/Unlock control, Siri/App Intents, widgets, and Action Button support.

This is a bench prototype and wiring reference, not a certified door lock, access-control system, or life-safety device.

[View the Phase 1 wiring diagram](https://bt1142msstate.github.io/door-unlocker/)

![Phase 1 desk-test wiring diagram](screenshots/phase-1-desktop-dark.png)

## What Is Included

- XIAO nRF52840 Sense firmware for BLE control, authenticated commands, servo movement, and onboard LED state.
- SwiftUI iPhone app for connecting over BLE and toggling between locked and unlocked states.
- Siri/App Shortcuts, WidgetKit home widget, and Control Widget support for iPhone Action Button controls.
- Interactive no-solder desk-test wiring diagram with hardware list, costs, and part details.
- Hardware notes for a battery-powered 2S setup using XT30 pigtails, WAGO lever nuts, a buck converter, and a breadboard.

## Hardware

Current Phase 1 desk-test parts:

- Seeed Studio XIAO nRF52840 Sense, pre-soldered.
- INJORA 35 kg high-torque digital servo.
- 25T metal servo arm with rubber end cap.
- 7.4 V 2S Li-ion battery with XT30 output.
- XT30 pigtails.
- LM2596 adjustable buck converter for the microcontroller rail.
- WAGO 222-413 3-conductor lever nuts for power splitting.
- Mini breadboard and jumper wires.

The servo power should come directly from the battery-side power split. The XIAO should be powered through the buck converter. The servo signal line can go through the breadboard because it is only carrying PWM signal, not servo motor current.

## Repository Layout

```text
assets/                         Rendered hardware images used by the wiring page
firmware/DoorUnlockerXiao/       Arduino firmware for the XIAO nRF52840
ios/DoorUnlockerApp/             SwiftUI iPhone app, widget, and control extension
screenshots/                     Project screenshots and visual references
phase-1-desk-test-wiring.html    Interactive desk-test wiring diagram
index.html                       GitHub Pages entry point
```

## Quick Start

1. Clone the repository.
2. Generate a private 32-byte command key:

   ```bash
   openssl rand -hex 32
   ```

3. Convert the generated hex into comma-separated bytes and paste the same bytes into:

   - `firmware/DoorUnlockerXiao/DoorUnlockerXiao.ino`
   - `ios/DoorUnlockerApp/DoorUnlocker/DoorCommandAuthenticator.swift`

4. Flash the XIAO firmware from the Arduino IDE.
5. Open `ios/DoorUnlockerApp/DoorUnlocker.xcodeproj` in Xcode.
6. Set your own Apple Developer Team, bundle identifiers, and App Group identifiers.
7. Build and run the iPhone app on your device.

The committed command key is a public sample key. Do not use it for real hardware.

## Firmware Notes

The firmware advertises a BLE peripheral for the iPhone app, verifies signed commands, drives the servo to locked or unlocked positions, and changes the XIAO LED color based on state.

Servo angles and timing are defined near the top of `firmware/DoorUnlockerXiao/DoorUnlockerXiao.ino`.

## iPhone App Notes

The app provides:

- One main state toggle for Lock/Unlock.
- BLE connection management.
- Siri/App Intents for voice and shortcut automation.
- A home screen widget.
- A Control Widget so the project can appear in iOS Controls and be assigned to the Action Button on supported iPhones.
- Alternate app icons for locked and unlocked states.

## Security And Safety

This project intentionally avoids publishing a private command key. Anyone building the project should generate their own key and flash/install matching firmware and app builds.

For anything beyond desk testing, review the mechanical mount, fail-safe behavior, battery handling, apartment rules, fire-safety requirements, and lock/egress requirements before use.

## License

MIT License. See [LICENSE](LICENSE).
