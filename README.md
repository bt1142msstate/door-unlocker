# Door Unlocker

Open-source desk-test prototype for a BLE-controlled servo actuator. The project uses a Seeed Studio XIAO nRF52840 Sense to drive a high-torque servo, plus SwiftUI iPhone and Mac apps for lock control, pairing, and controller administration.

This is a bench prototype and wiring reference, not a certified door lock, access-control system, or life-safety device.

Current release: `v0.1.0-beta.2`, the current usable beta. The authenticated wireless command path is in place, but the hardware, multi-device behavior, battery setup, and enclosure still need longer real-world testing before a stable release.

Latest beta firmware: `0.1.0-beta.ota13`.

## Latest Beta Validation

The `v0.1.0-beta.2` cut was tested on 2026-07-07 against the bench XIAO controller and the iPhone/Mac apps.

Observed iPhone startup timing from `script/benchmark_ios_startup.sh`:

- `controller_init`: 1 ms
- `central_created`: 4 ms
- `central_restored`: 76 ms
- `gatt_ready`: 76 ms
- `secure_nonce_received`: 134 ms
- `door_command_usable nonce_ready`: 134 ms
- `first_fast_payload_ready UNLOCK`: 141 ms

Validation run:

- iPhone app installed through `script/install_ios_app.sh`, which builds for `generic/platform=iOS` and installs with `devicectl`.
- iOS generic device build passed with `CODE_SIGNING_ALLOWED=NO`.
- Mac admin package tests passed: 6 tests.
- Mac admin build/run verification passed with `script/build_and_run.sh --verify`.
- Controller status verified over USB-C after OTA: `model=DoorUnlocker-XIAO-v4`, `firmware_version=0.1.0-beta.ota13`.
- Mac OTA path verified by updating to `0.1.0-beta.ota12`.
- iPhone OTA path verified by updating to `0.1.0-beta.ota13`.

[View the Phase 1 wiring diagram](https://bt1142msstate.github.io/door-unlocker/)

![Phase 1 desk-test wiring diagram](screenshots/phase-1-desktop-dark.png)

## What Is Included

- XIAO nRF52840 Sense firmware for BLE control, authenticated commands, servo movement, and onboard LED state.
- SwiftUI iPhone app for connecting over BLE and toggling between locked and unlocked states.
- SwiftUI Mac admin app for USB-C controller management, Bluetooth lock/unlock, pairing approval, and trusted-device removal.
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

With the XIAO component side facing up and the USB-C connector at the top:

- Servo signal uses XIAO `D2`: third pin down on the left side.
- Common ground uses XIAO `GND`: second pin down on the right side.
- Servo ground, battery negative, buck ground, and XIAO `GND` must all share the same ground reference.

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
8. Read the 4-digit code shown on the iPhone, then type that code into the Mac admin app or send `pair approve CODE` over USB serial.
9. Use the main toggle, Siri/App Shortcuts, widgets, iOS Controls, or the Mac admin app after pairing completes.
10. To pair the Mac for wireless control, request Mac pairing from the Mac app, then approve it from a separate USB serial/admin flow. The Mac app intentionally does not display its own approval code.

The iPhone and Mac apps each generate their own P-256 signing key locally. They prefer Secure Enclave when available and fall back to a Keychain-stored software key when needed. The XIAO stores only trusted device public keys, so the repository does not contain a command secret.

## Firmware Notes

The firmware advertises a BLE peripheral for the iPhone and Mac apps, stores up to four paired device public keys in internal flash, allows up to four simultaneous BLE central connections, verifies signed `v3` commands, drives the servo to locked or unlocked positions, and changes the XIAO LED color based on state.

Unlock commands hold the servo at the unlock angle for up to 30 seconds by default. The iPhone and Mac apps can set the controller timeout from 5-120 seconds, and the XIAO stores that value locally. After the configured timeout, the controller automatically returns to the locked/rest position to reduce battery drain and servo stress.

The controller also stores the last unlock timestamp locally. The apps include their current epoch time when sending an unlock command, and the XIAO persists that value so the iPhone and Mac apps can display the controller's last recorded unlock time.

Servo calibration is also controller-owned. The default rest angle is `20` degrees and the default push angle is `95` degrees. Apps and USB commands can set both values, but the firmware rejects angles outside `10`-`170` degrees or angles closer than `10` degrees apart.

USB serial commands:

- `pair on`: enable BLE pairing requests.
- `pair approve CODE`: approve the pending device if the code matches the device being paired.
- `pair reject`: reject the pending device request.
- `pair off`: disable BLE pairing mode and clear any pending request.
- `pair status`: print pairing mode, pending request, and paired device count.
- `pairs list`: print paired device slots, fingerprints, and names when known.
- `pairs remove N`: remove one paired device by slot number.
- `pairs clear`: remove all paired devices.
- `app status`: print machine-readable model, state, pairing, timeout, servo-angle, and last-unlock status for the Mac admin app.
- `app pairs`: print machine-readable paired-device slots, fingerprints, counters, and names when known.
- `app unlock [EPOCH_SECONDS]`: move the actuator and optionally save the controller-owned last-unlock timestamp.
- `app angles REST PUSH`: set persisted servo rest and push angles, for example `app angles 20 95`.
- `app pair on` / `app pair off`: enable or disable USB-gated pairing from the Mac admin app.
- `app approve CODE` / `app reject`: approve or reject a pending device request from the Mac admin app.
- `app remove N`: remove one paired device by slot number from the Mac admin app.
- `app lock` / `app unlock`: move the actuator from the Mac admin app over trusted USB.
- `app bootloader`: reboot the XIAO into UF2 bootloader mode for firmware updates.

LED states:

- Red: no trusted device can command the controller and USB pairing mode is locked.
- Purple: USB pairing mode is enabled and waiting for a device request.
- Cyan: a device pairing request is pending USB approval.
- Blue: locked.
- Green: unlocked.
- Yellow: servo is moving.

Servo angle defaults, safety limits, and timing constants are defined near the top of `firmware/DoorUnlockerXiao/DoorUnlockerXiao.ino`; the live angle values are stored on the controller after calibration.

## iPhone App Notes

The app provides:

- One main state toggle for Lock/Unlock.
- BLE connection management.
- USB-gated pairing that sends only the phone public key to the XIAO and requires typing the 4-digit code shown on the phone over USB-C or in the Mac admin app.
- Optional Face ID/passcode confirmation before sending unlock commands.
- Auto-lock timeout setting that is stored and enforced by the controller.
- Servo rest/push angle calibration stored and enforced by the controller.
- Editable iPhone display name that updates the trusted-device record without re-pairing.
- Optional unlock notifications when the controller reports `unlocked` while the app is in the background.
- Siri/App Intents for voice and shortcut automation.
- A home screen widget.
- A Control Widget so the project can appear in iOS Controls and be assigned to the Action Button on supported iPhones.
- Alternate app icons for locked and unlocked states.

## Mac Admin App Notes

The Mac admin app is in `mac/DoorUnlockerAdmin`. It automatically connects to the XIAO over USB-C serial at 115200 baud when the controller is plugged in, trusts the Mac over that USB-C admin channel, and auto-connects over Bluetooth when wireless control is available.

- Show controller model, state, pairing mode, auto-lock timeout, live auto-lock countdown, and trusted-device count.
- List trusted devices by friendly name when known, plus slot and public-key fingerprint.
- Enable or disable pairing mode.
- Approve or reject a pending iPhone pairing request by typing the 4-digit code shown on the phone.
- Automatically trust the Mac over USB-C for wireless control.
- Remove one trusted device, clear all trusted devices, or send lock/unlock over USB.
- Set controller-owned auto-lock timeout and servo rest/push angles.
- Auto-connect over Bluetooth when available and use the same Lock/Unlock toggle as the iPhone app.
- Provide a local CLI for scripts and automation.

The Mac admin app does not display pending approval codes or pending public-key fingerprints. Device names are stored by the firmware for new pairings. Existing pairings made before this feature may show as `Device 1`, `Device 2`, and so on until that device is paired again.

iOS may hide the user-assigned system device name from apps, so the iPhone app keeps its own Door Unlocker display name. Updating that name sends an authenticated rename command to the controller; it does not require deleting or re-pairing the phone.

For background widget updates, the app stores each BLE state update in the shared app group and asks WidgetKit to reload the Door Unlocker widget. The app also enables the `bluetooth-central` background mode so iOS can wake it for controller BLE activity when allowed. iOS can still defer or skip background widget refreshes, especially if the app was force-quit, Background App Refresh is disabled, Bluetooth permission is denied, or Low Power Mode is limiting background work.

Run it locally with:

```sh
./script/build_and_run.sh
```

CLI examples:

```sh
cd mac/DoorUnlockerAdmin
swift run door-unlocker status
swift run door-unlocker lock
swift run door-unlocker unlock
swift run door-unlocker bootloader
```

## Firmware Update Process

`script/flash_xiao_uf2.sh --build-only` compiles the Arduino firmware and creates both update formats:

- `dist/DoorUnlockerXiao.uf2` for USB-C UF2 recovery flashing.
- `dist/DoorUnlockerXiao-dfu.zip` for BLE OTA DFU from the iPhone or Mac app.

For USB-C recovery or first-time flashing, use:

```sh
./script/flash_xiao_uf2.sh --port /dev/cu.usbmodem3101
```

When the installed firmware supports `app bootloader`, the script asks the running controller to reboot into UF2 bootloader mode, then copies the UF2 to `/Volumes/XIAO-SENSE`. If the installed firmware is too old to enter UF2 mode from USB-C, the script pauses for a one-time reset-button double press. The script uses `cp -X` when copying the UF2 so macOS does not add metadata files to the XIAO bootloader volume.

For app-driven OTA updates, the controller must already trust the app issuing the update command. The trusted app sends the signed `ENTER_OTA_DFU` command, the controller enters BLE DFU mode, the app uploads `DoorUnlockerXiao-dfu.zip`, then the controller reboots and the app verifies the reported firmware version. USB-C remains the recovery fallback if an OTA attempt is interrupted.

For iPhone OTA testing, bundle the current DFU package at:

```text
ios/DoorUnlockerApp/DoorUnlocker/Firmware/DoorUnlockerXiao-dfu.zip
```

For Mac OTA testing, build the package and send it through the admin app/CLI flow:

```sh
./script/flash_xiao_uf2.sh --build-only
mac/DoorUnlockerAdmin/.build/debug/door-unlocker firmware dist/DoorUnlockerXiao-dfu.zip
```

The XIAO UF2 bootloader is separate from Door Unlocker firmware. Normal updates should use the signed Door Unlocker DFU/UF2 app firmware packages and should not rewrite the bootloader. Bootloader maintenance is a recovery-only task: verify the currently installed bootloader from the XIAO bootloader volume before changing it, and only flash a board-specific Seeed/Adafruit nRF52 bootloader build when there is a real compatibility or recovery reason.

As of 2026-07-07, the latest upstream Adafruit nRF52 bootloader release is `0.11.0`, and CircuitPython documents that nRF UF2 bootloader `0.6.1` or newer is enough for current nRF UF2 firmware loading. Door Unlocker does not require a bootloader update when the controller already responds to `app status`, USB-C UF2 flashing works, and BLE OTA DFU works.

That build also creates `dist/door-unlocker`, a USB-C command-line tool:

```sh
./dist/door-unlocker status
./dist/door-unlocker unlock
./dist/door-unlocker lock
./dist/door-unlocker toggle
./dist/door-unlocker timeout 30
./dist/door-unlocker angles 20 95
./dist/door-unlocker pairs
./dist/door-unlocker rename 1 "Brandon's iPhone"
```

Use `./dist/door-unlocker --help` for the full command list. The CLI auto-detects the XIAO serial port by default and also accepts `--port /dev/cu.usbmodemXXXX`.
When the Mac app is already running, `lock`, `unlock`, `toggle`, `timeout`, and `angles` are handed to the app locally so the CLI does not compete with the app for the USB-C serial stream.

## Roadmap

- Controller/app usage stats: track values such as daily unlock counts and recent lock/unlock history. Keep this local-first and privacy-preserving, with the controller as the source of truth where practical.

## Security And Safety

This project intentionally avoids publishing a command secret. The iPhone and Mac apps sign each wireless command with a locally generated private key, and the XIAO verifies the signature with the paired public key.

BLE pairing is locked unless USB-C serial pairing mode is enabled. A device can submit a pairing request only after `pair on`, and it is not trusted until the USB-side operator types `pair approve CODE` with the code shown in the app or approves the same code in the Mac admin app. Pairing mode turns itself off after approval. If an app is deleted, a device is replaced, or a signing key is lost, connect over USB-C, send `pair on`, and pair the replacement device. Use `pairs remove N`, `app remove N`, or `pairs clear` over USB-C if you need to remove trusted devices.

For anything beyond desk testing, review the mechanical mount, fail-safe behavior, battery handling, apartment rules, fire-safety requirements, and lock/egress requirements before use.

## License

MIT License. See [LICENSE](LICENSE).
