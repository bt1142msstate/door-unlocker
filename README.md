# Door Unlocker

Open-source desk-test prototype for a BLE-controlled servo actuator. The project uses a Seeed Studio XIAO nRF52840 Sense to drive a high-torque servo, plus a SwiftUI iPhone app with Lock/Unlock control, Siri/App Intents, widgets, and Action Button support.

This is a bench prototype and wiring reference, not a certified door lock, access-control system, or life-safety device.

[View the Phase 1 wiring diagram](https://bt1142msstate.github.io/door-unlocker/)

![Phase 1 desk-test wiring diagram](screenshots/phase-1-desktop-dark.png)

## What Is Included

- XIAO nRF52840 Sense firmware for BLE control, authenticated commands, servo movement, and onboard LED state.
- SwiftUI iPhone app for connecting over BLE and toggling between locked and unlocked states.
- SwiftUI Mac admin app for USB-C controller management, pairing approval, trusted-device removal, and direct lock/unlock.
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
mac/DoorUnlockerAdmin/           SwiftUI Mac admin app for USB-C controller management
screenshots/                     Project screenshots and visual references
phase-1-desk-test-wiring.html    Interactive desk-test wiring diagram
index.html                       GitHub Pages entry point
```

## Quick Start

1. Clone the repository.
2. Flash the XIAO firmware from the Arduino IDE.
3. Open `ios/DoorUnlockerApp/DoorUnlocker.xcodeproj` in Xcode.
4. Set your own Apple Developer Team, bundle identifiers, and App Group identifiers.
5. Build and run the iPhone app on your device.
6. Open the XIAO serial monitor over USB-C and send `pair on`.
7. Connect to the XIAO from the iPhone app and tap **Pair This iPhone** while the app shows `Pairing Enabled`.
8. Compare the code shown in the app with the USB serial output, then type `pair approve CODE`, or open the Mac admin app and approve the code there.
9. Use the main toggle, Siri/App Shortcuts, widgets, iOS Controls, or the Mac admin app after pairing completes.

The app generates its own P-256 signing key locally. It prefers Secure Enclave when available and falls back to a Keychain-stored software key when needed. The XIAO stores only the phone's public key, so the repository does not contain a command secret.

## Firmware Notes

The firmware advertises a BLE peripheral for the iPhone app, stores up to four paired phone public keys in internal flash, verifies signed `v2` commands, drives the servo to locked or unlocked positions, and changes the XIAO LED color based on state.

Unlock commands hold the servo at the unlock angle for up to 30 seconds by default. The iPhone app can set the controller timeout from 5-120 seconds, and the XIAO stores that value locally. After the configured timeout, the controller automatically returns to the locked/rest position to reduce battery drain and servo stress.

USB serial commands:

- `pair on`: enable BLE pairing requests.
- `pair approve CODE`: approve the pending phone if the code matches the iPhone app.
- `pair reject`: reject the pending phone request.
- `pair off`: disable BLE pairing mode and clear any pending request.
- `pair status`: print pairing mode, pending request, and paired phone count.
- `pairs list`: print paired phone slots and fingerprints.
- `pairs remove N`: remove one paired phone by slot number.
- `pairs clear`: remove all paired phones.
- `app status`: print machine-readable status for the Mac admin app.
- `app pairs`: print machine-readable paired-device slots and fingerprints.
- `app pair on` / `app pair off`: enable or disable USB-gated pairing from the Mac admin app.
- `app approve CODE` / `app reject`: approve or reject a pending phone request from the Mac admin app.
- `app remove N`: remove one paired phone by slot number from the Mac admin app.
- `app lock` / `app unlock`: move the actuator from the Mac admin app over trusted USB.

LED states:

- Red: no phone can command the controller and USB pairing mode is locked.
- Purple: USB pairing mode is enabled and waiting for a phone request.
- Cyan: a phone pairing request is pending USB approval.
- Blue: locked.
- Green: unlocked.
- Yellow: servo is moving.

Servo angles and timing are defined near the top of `firmware/DoorUnlockerXiao/DoorUnlockerXiao.ino`.

## iPhone App Notes

The app provides:

- One main state toggle for Lock/Unlock.
- BLE connection management.
- USB-gated pairing that sends only the phone public key to the XIAO and requires typing the app's approval code over USB-C.
- Optional Face ID/passcode confirmation before sending unlock commands.
- Auto-lock timeout setting that is stored and enforced by the controller.
- Siri/App Intents for voice and shortcut automation.
- A home screen widget.
- A Control Widget so the project can appear in iOS Controls and be assigned to the Action Button on supported iPhones.
- Alternate app icons for locked and unlocked states.

## Mac Admin App Notes

The Mac admin app is in `mac/DoorUnlockerAdmin` and talks to the XIAO over USB-C serial at 115200 baud. It can:

- Show controller state, pairing mode, auto-lock timeout, and trusted-device count.
- List trusted phones by slot and public-key fingerprint.
- Enable or disable pairing mode.
- Approve or reject a pending phone pairing request by typing the code shown in the iPhone app.
- Remove one trusted phone, clear all trusted phones, or send lock/unlock over USB.

Run it locally with:

```sh
./script/build_and_run.sh
```

## Security And Safety

This project intentionally avoids publishing a command secret. The phone signs each command with a locally generated private key, and the XIAO verifies the signature with the paired public key.

BLE pairing is locked unless USB-C serial pairing mode is enabled. A phone can submit a pairing request only after `pair on`, and it is not trusted until the USB-side operator types `pair approve CODE` with the code shown in the iPhone app or approves the same code in the Mac admin app. Pairing mode turns itself off after approval. If the app is deleted, the phone is replaced, or the signing key is lost, connect over USB-C, send `pair on`, and pair the replacement phone. Use `pairs remove N`, `app remove N`, or `pairs clear` over USB-C if you need to remove trusted phones.

For anything beyond desk testing, review the mechanical mount, fail-safe behavior, battery handling, apartment rules, fire-safety requirements, and lock/egress requirements before use.

## License

MIT License. See [LICENSE](LICENSE).
