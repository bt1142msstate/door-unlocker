# Door Unlocker

Open-source desk-test prototype for a BLE-controlled servo actuator. The project uses a Seeed Studio XIAO nRF52840 Sense to drive a high-torque servo, plus SwiftUI iPhone and Mac apps for lock control, pairing, and controller administration.

Current stable beta: `v0.3.0-beta.1`, with iPhone/Mac app version `0.3.0` build `4`. The current development controller firmware is `0.1.32`. The previous stable release is `v0.2.1`.

This is a bench prototype and wiring reference, not a certified door lock, access-control system, or life-safety device.

The consumer app is planned as a free iOS App Store download. A free Android app and Google Play release are also on the roadmap. This repository is public and open source today; long-term source availability and licensing for later commercial generations are still under evaluation, while the downloadable consumer apps are intended to remain free.

## Stable Beta Validation

`v0.3.0-beta.1` packages the shared command path, signed wireless firmware updates, updater progress visibility, and multi-client synchronization work. The current bootloader candidate uses the upstream Nordic dual-bank activation path after the custom activation path caused a verified upload to boot the old application. Exact-build USB recovery now passes; it remains a prerelease until the remaining content-bound physical power-loss and interruption campaign passes. See [the v0.3.0 beta readiness report](docs/release-readiness-v0.3.0-beta.1.md) and [the activation incident report](docs/ota-activation-incident-2026-07-13.md).

Validation run:

- iPhone install path remains `script/install_ios_app.sh`, which builds for `generic/platform=iOS` and installs with `devicectl`.
- iPhone wireless debug/monitor path is documented in `docs/ios-wireless-debugging.md`; use `script/ios_device_status.sh --require-wireless` and `script/monitor_ios_app.sh --wireless-only` to prove the no-cable path.
- iPhone physical-device build/install passed with the bundled DFU package.
- The corrected bootloader completed consecutive `0.1.30 -> 0.1.31 -> 0.1.32` signed BLE transitions with no controller USB connection and post-reboot version verification.
- Hardware reported recovery build ID `b2409e808fefca642042`; the read-only USB mount and signed serial recovery exercise returned to `0.1.32` with pairings and settings preserved.
- Mac package build passed with `swift build --package-path mac/DoorUnlockerAdmin`.
- Mac build/run install path passed with `script/build_and_run.sh --install`.
- The latest fast campaign passed 12 of 14 gates. Firmware/package verification and shared/Mac tests pass; the maintainability score and content-bound physical iPhone launch recollection remain open.
- The preceding physical iPhone baseline passed 10 cold and 10 warm samples, but source and release-version changes intentionally invalidate it as proof for this tag.
- Earlier live release checks passed repeated app relaunch, alternating iPhone/Mac commands, and cross-client setting changes; they remain historical evidence rather than exact-tag proof.
- Latest recorded quality scores: maintainability `84.8/100`, shared parity `100/100`, iOS modularity `96.7/100`, and Mac modularity `98.4/100`.

The machine-readable physical proofs are in [docs/firmware-release-proof.json](docs/firmware-release-proof.json) and [docs/ios-launch-performance-last-run.json](docs/ios-launch-performance-last-run.json). Historical OTA tuning and benchmark details are kept in [docs/ota-speed-plan.md](docs/ota-speed-plan.md).

[View the Phase 1 wiring diagram](https://bt1142msstate.github.io/door-unlocker/)

![Phase 1 desk-test wiring diagram](screenshots/phase-1-desktop-dark.png)

## What Is Included

- XIAO nRF52840 Sense firmware for BLE control, authenticated commands, servo movement, and onboard LED state.
- SwiftUI iPhone app for connecting over BLE and toggling between locked and unlocked states.
- SwiftUI Mac app for USB-C recovery administration, Bluetooth lock/unlock, pairing approval, and trusted-device removal.
- Siri/App Shortcuts, WidgetKit home widget, and Control Widget support for iPhone Action Button controls.
- Interactive no-solder desk-test wiring diagram with hardware list, costs, and part details.
- Hardware notes for a battery-powered 2S setup using XT30 pigtails, compact inline lever splitters, a buck converter, and a breadboard.
- Phase 2 enclosure, mounting, fit, and force documentation in [`cad/`](cad/) and [`docs/`](docs/).
- An optimal component direction document for the lower-power enclosure path: [docs/optimal-components.md](docs/optimal-components.md).
- A documented, cross-platform low-latency control contract: [docs/fast-lock-command-path.md](docs/fast-lock-command-path.md).
- A calibrated full quality suite with iOS/Mac adapter parity tests and explicit evidence limits: [docs/quality-suite.md](docs/quality-suite.md).

## Hardware

Current Phase 1 desk-test parts:

- Seeed Studio XIAO nRF52840 Sense, pre-soldered.
- INJORA 35 kg high-torque digital servo.
- 25T metal servo arm with rubber end cap.
- 7.4 V 2S Li-ion battery with XT30 output.
- XT30 pigtails.
- LM2596 adjustable buck converter for the microcontroller rail.
- Two XALXMAW 1-in/2-out inline lever splitters: one for positive and one for common ground.
- Mini breadboard and jumper wires.

The servo power should come directly from the battery-side power split. The XIAO should be powered through the buck converter. The servo signal line can go through the breadboard because it is only carrying PWM signal, not servo motor current.

> **Power warning:** do not connect the XIAO's external buck-fed `5V` rail while USB-C is also powering the board. Disconnect USB-C before enabling the external controller rail, verify buck output with a meter first, and keep all grounds common.

The current LM2596 and no-solder wiring are prototype-friendly, not the final low-power target. The optimized hardware direction is to use one protected 2S pack, a low-quiescent 2S-capable buck for the controller rail, a true high-side servo power switch, switched battery measurement or a multi-cell fuel gauge, and protected 2S solar charging. See [docs/optimal-components.md](docs/optimal-components.md) for the current preferred component direction and source links.

With the XIAO component side facing up and the USB-C connector at the top:

- Servo signal uses XIAO `D2`: third pin down on the left side.
- Common ground uses XIAO `GND`: second pin down on the right side.
- Servo ground, battery negative, buck ground, and XIAO `GND` must all share the same ground reference.

## Repository Layout

```text
assets/                         Rendered hardware images used by the wiring page
firmware/DoorUnlockerXiao/       Arduino firmware for the XIAO nRF52840
ios/DoorUnlockerApp/             SwiftUI iPhone app, widget, and control extension
mac/DoorUnlockerAdmin/           SwiftUI Mac app with wireless and USB-C administration
shared/DoorUnlockerShared/       Cross-platform command, BLE policy, parser, signing, and DFU modules
cad/                            Parametric Phase 2 enclosure and mounting models
docs/                           Architecture, validation, power, fit, and force documentation
script/                         Build, install, firmware, simulation, and quality-gate tooling
tools/DoorUnlockerHandoff/      Native spoken handoff UI for attended hardware tests
screenshots/                     Project screenshots and visual references
phase-1-desk-test-wiring.html    Interactive desk-test wiring diagram
index.html                       GitHub Pages entry point
```

The iPhone and Mac apps share two Swift package products. `DoorUnlockerShared` owns the lock/unlock command model, secure wire-packet assembly, parser/models, safety limits, write/recovery decisions, controller-setting formatting, and control presentation policy. `DoorUnlockerDFU` owns the complete Nordic BLE firmware-update transport and progress/ETA model. Platform targets retain only platform integrations such as local signing-key storage, iOS background/proximity behavior, Mac USB serial administration, and native UI.

`script/score_shared_parity.py` prevents shared contracts from drifting back into app-specific copies, and the full quality suite compiles/tests the shared package, both platform adapters, and both apps.

## Quick Start

Requirements: macOS with Xcode, `arduino-cli`, the Seeed nRF52 board package, a physical iPhone for BLE testing, and the hardware listed above.

1. Clone the repository and connect the XIAO over USB-C.
2. Build and flash the controller with `./script/flash_xiao_uf2.sh`. Use `--build-only` when you only need release artifacts.
3. Put your Apple team ID in the ignored file `ios/DoorUnlockerApp/development-team.local`, or export `DEVELOPMENT_TEAM=<team-id>`.
4. Install the iPhone app with `./script/install_ios_app.sh`. Add `--wireless-only` after Xcode has enabled wireless device connectivity.
5. Install the Mac app and CLI with `./script/build_and_run.sh --install`.
6. Enable pairing from USB-C with `pair on`, or use an already trusted iPhone/Mac to open pairing wirelessly.
7. Request pairing on the new device, read its 4-digit code, and approve that code from an already trusted device or with `pair approve CODE` over USB serial.
8. Use the main toggle, Siri/App Shortcuts, widget, iOS Control, Action Button, Mac app, or local CLI after pairing completes.

The checked-in Apple signing settings are intentionally blank. Change bundle and App Group identifiers if you are distributing your own fork. Core Bluetooth hardware behavior cannot be validated in the iOS Simulator.

The iPhone and Mac apps each generate a separate P-256 signing identity. The iPhone prefers Secure Enclave and falls back to a Keychain-stored software key. The Mac stores its software key under Application Support with owner-only file permissions. The XIAO stores trusted public keys only, so the repository does not contain a shared command secret.

## Firmware Notes

The firmware advertises a BLE peripheral for the iPhone and Mac apps, stores up to four paired device public keys in internal flash, allows up to four simultaneous BLE central connections, verifies signed `v3` commands, drives the servo to locked or unlocked positions, and changes the XIAO LED color based on state.

Unlock commands hold the servo at the unlock angle for up to 30 seconds by default. The iPhone and Mac apps can set the controller timeout from 5-120 seconds, and the XIAO stores that value locally. After the configured timeout, the controller automatically returns to the locked/rest position to reduce battery drain and servo stress.

The controller can store an optional command timestamp with lock/unlock activity for future local history features. The current apps intentionally do not present an unlock-history panel.

Servo calibration is controller-owned. The default rest angle is `95` degrees and the default push angle is `20` degrees for the current arm setup, so unlock rotates the arm to the right. Apps and USB commands can set both values. Each angle is clamped to `10`-`170` degrees; equal or crossing values are allowed for calibration, although equal values produce no movement.

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
- `app lock [EPOCH_SECONDS]` / `app unlock [EPOCH_SECONDS]`: move the actuator and optionally save a command timestamp.
- `app angles REST PUSH`: set persisted servo rest and push angles, for example `app angles 95 20`.
- `app timeout SECONDS`: set the persisted 5-120 second auto-lock timeout.
- `app lock name NAME`: set the controller-owned lock name.
- `app rename SLOT_OR_FINGERPRINT NAME`: rename a trusted device.
- `app pair on` / `app pair off`: enable or disable USB-C pairing from the Mac admin app.
- `app approve CODE` / `app reject`: approve or reject a pending device request from the Mac admin app.
- `app remove N`: remove one paired device by slot number from the Mac admin app.
- `app lock` / `app unlock`: move the actuator from the Mac admin app over trusted USB.
- `app bootloader`: reboot the XIAO into UF2 bootloader mode for firmware updates.
- `app ota`: reboot into BLE OTA DFU mode for recovery/testing.
- `app cleanup untrusted`: disconnect currently untrusted BLE links.

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
- Trusted-device pairing that sends only the new phone public key to the XIAO and requires typing the 4-digit code shown on the new phone into an already trusted iPhone/Mac or USB-C admin flow.
- Invite flow for adding a new iPhone: a trusted phone opens pairing mode, shares a non-secret `doorunlocker://pair` link, then approves the 4-digit code shown on the new device.
- Optional Face ID/passcode confirmation before sending unlock commands.
- Auto-lock timeout setting that is stored and enforced by the controller.
- Servo rest/push angle calibration stored and enforced by the controller.
- Editable controller-owned lock name shared across trusted devices and widgets.
- Editable iPhone display name that updates the trusted-device record without re-pairing.
- Optional proximity unlock with a location-based arming zone, precise-location support, configurable BLE RSSI trigger, feet/meters display, and an expanded direction map.
- Optional unlock notifications when the controller reports `unlocked` while the app is in the background.
- Siri/App Intents for voice and shortcut automation.
- A state-aware home screen widget and lock/unlock Live Activity with Dynamic Island presentation on supported iPhones.
- A Control Widget so the project can appear in iOS Controls and be assigned to the Action Button on supported iPhones.
- Original, monochrome, gold, aurora, pink, red, ember, and violet color themes.

## Mac App Notes

The Mac app is named **Door Unlocker**, matching the iPhone app. Its source package remains in `mac/DoorUnlockerAdmin` because it owns the additional trusted-device and USB-C administration features. It automatically connects to the XIAO over USB-C serial at 115200 baud when the controller is plugged in, trusts the Mac over that USB-C admin channel, and auto-connects over Bluetooth when wireless control is available.

- Show controller model, state, pairing mode, auto-lock timeout, live auto-lock countdown, and trusted-device count.
- List trusted devices by friendly name when known, plus slot and public-key fingerprint.
- Enable or disable pairing mode over trusted wireless control or USB-C.
- Approve or reject a pending device pairing request by typing the 4-digit code shown on the new device.
- Automatically trust the Mac over USB-C for wireless control.
- Remove one trusted device, clear all trusted devices, or send lock/unlock over USB.
- Set controller-owned auto-lock timeout and servo rest/push angles.
- Auto-connect over Bluetooth when available and use the same Lock/Unlock toggle as the iPhone app.
- Show controller firmware and connected-device state, and install the same BLE DFU package used by iPhone.
- Provide a local CLI for scripts and automation.

The Mac app does not display pending approval codes or pending public-key fingerprints. Device names are stored by the firmware for new pairings. Existing pairings made before this feature may show as `Device 1`, `Device 2`, and so on until that device is paired again.

`./script/build_and_run.sh --install` replaces the canonical local bundle at `~/Applications/Door Unlocker.app`. The installer preserves the existing trusted bundle identity and local data while removing the legacy `DoorUnlockerAdmin.app` bundle after the replacement verifies successfully.

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
- `dist/DoorUnlockerXiao-dfu.zip` for the factory `AdaDFU` bootloader (legacy CRC16 envelope).
- `dist/DoorUnlockerXiao-signed-dfu.zip` for the signed `DoorDFU` candidate (P-256 ECDSA envelope).

The build script compiles the controller with `-Os` by default to keep OTA packages small without changing firmware behavior. Set `XIAO_OPTIMIZATION_FLAG=-Ofast` when running the script if you need to reproduce the stock Seeed board-package optimization setting.

For USB-C recovery or first-time flashing, use:

```sh
./script/flash_xiao_uf2.sh --port /dev/cu.usbmodem3101
```

When the installed firmware supports `app bootloader`, the script asks the running controller to reboot into its USB bootloader. A reset-button double press is the app-independent fallback. The signed Door Unlocker bootloader mounts `/Volumes/XIAO-SENSE` read-only so recovery mode is visible, then accepts the signed application package through USB CDC serial DFU. Factory bootloaders may still use the writable UF2 copy path. Run `python3 script/verify_usb_recovery.py --exercise --write-proof` while the signed bootloader is mounted to exercise and record the exact recovery path.

For app-driven OTA updates, the controller must already trust the app issuing the update command. The trusted app sends the signed `ENTER_OTA_DFU` command, then chooses the compatible package after discovering the bootloader: factory `AdaDFU` receives CRC16 and custom `DoorDFU` receives ECDSA. Both apps persist an update journal and, after relaunch, first reconcile normal firmware before probing DFU mode. Transient interruptions retry at most three upload attempts; integrity/signature/CRC failures stop instead of looping. USB-C remains the recovery fallback.

The product update policy is wireless-first. Trusted iPhone and Mac clients can install both signed application firmware and signed bootloader-only replacements, so routine controller software and transport changes do not require controller USB-C. Nordic's package format can also carry SoftDevice changes, but this project has not yet physically qualified S140 replacement or signing-key rotation on the exact hardware. USB-C/SWD remain recovery paths for a nonresponsive radio, bootloader-level corruption, or physical hardware service; they are not the routine delivery mechanism.

Firmware may be promoted to a release only after `python3 script/quality_suite.py --firmware-release` passes. In addition to the exact-package BLE proof, that mode requires two consecutive no-USB OTA transitions, exact-candidate signed USB recovery, proof that the signed dual-bank bootloader is installed, unsigned-image rejection, and the physical power-loss campaign. Normal application ZIPs are structurally rejected if they contain a bootloader, MBR, or SoftDevice image, so routine firmware versions cannot overwrite the recovery bootloader.

The pinned Adafruit `0.11.0` bootloader also uses the nRF52840 ACL peripheral
to block the running application from writing the MBR or the bootloader and
settings region. Every application release preserves three software recovery
paths: normal signed BLE OTA, automatic BLE DFU when the application is
invalid, and app-independent USB CDC recovery after a reset-button double
press. SWD/J-Link remains the final hardware recovery method for total MBR or
bootloader corruption; no software-only design can recover when no trusted
code can execute. See the [firmware recovery runbook](docs/firmware-recovery-runbook.md).

The iPhone app also carries a bundled controller firmware version in `DoorControllerFirmwareVersion`. When the app connects, reads a known controller firmware version, and sees that the bundled firmware is newer, it can start the same secure OTA path automatically without a manual update button press. The app intentionally does not auto-update when the controller version is `Unknown` and does not downgrade a controller that reports a newer version than the bundled package.

Normal firmware updates should preserve the controller's stored pairings, lock name, timeout, and servo angles. Do not run `pairs clear`, delete trusted devices, or re-pair the iPhone just because an OTA or UF2 update was performed. Re-pair only when the app key was actually lost, such as after deleting/reinstalling the app or replacing the phone.

The controller keeps the servo signal attached while the lock is in the unlocked state so the arm can hold pressure on the handle until auto-lock or a manual lock command. After returning to the locked/rest angle, the firmware detaches the servo signal to reduce idle power draw and heat.

The current firmware `0.1.32` application payload is approximately `135 KB`. The fixed-15 trusted-iPhone wireless-only proof produced three consecutive signed uploads at `15,149`, `16,300`, and `17,170 B/s` and verified the rebooted controller over BLE with controller USB-C unplugged. The app logs scan, selected package profile, progress, throughput, completion, and failures.

The measured default is PRN `9` on both iPhone and Mac. The repository vendors NordicDFU `4.16.0` with a focused packet-sizing patch: known `AdaDFU` and project-owned `DoorDFU*` bootloaders use negotiated writes up to `244` bytes, while unknown bootloaders stay at `20`. The prefix match is contract-checked so names such as `DoorDFUStable` cannot silently fall back to 20-byte writes. The signed release bootloader uses a fixed `15ms` connection interval, automatic PHY, 16 HCI receive buffers, 18 flash-queue entries, and the proven flash-write pacing policy. Forced 2 Mbps, a 30ms interval, larger queues, zero flash latency, and PRN `0`, `4`, or `32` all regressed exact-hardware throughput. Physical app-termination tests at 30% and 80% and a forced BLE transport loss at 40% all recovered and validated.

The exact `v0.3.0-beta.1` Mac release-proof run exposed an exact-name compatibility bug: `DoorDFUStable` fell through a `DoorDFU`-only gate and used 20-byte writes, yielding roughly `1.2 KB/s`. The shared iPhone/macOS DFU layer now recognizes the project-owned `DoorDFU*` family. A physical wireless-only iPhone proof selected 244-byte writes and uploaded the signed 135 KB package in `6.12s`, restoring roughly `22-25 KB/s` progress throughput. A following Mac proof improved from `111s` to `40s`; macOS remains slower than iOS but no longer uses the legacy 20-byte fallback.

The speed research, bottleneck analysis, and next benchmark matrix live in [`docs/ota-speed-plan.md`](docs/ota-speed-plan.md). The stable apps share one DFU tuning model so iPhone and Mac updates use the same default path. For controlled iPhone benchmark runs, the verifier accepts debug-only launch overrides:

```sh
DFU_PRN=8 DFU_OBJECT_PREP_DELAY=0.3 ./script/verify_ios_ota.sh --wireless-only --target <new-version>
```

To compare the stable and candidate tuning paths repeatedly, run the matrix wrapper:

```sh
./script/benchmark_ios_ota_matrix.sh --target <new-version> --runs 3
```

If command-line iPhone signing needs your local Apple team, keep the repository settings blank and pass it only as an environment override:

```sh
DEVELOPMENT_TEAM=<team-id> ./script/benchmark_ios_ota_matrix.sh --target <new-version> --runs 3
```

For iPhone OTA testing, bundle the current DFU package at:

```text
ios/DoorUnlockerApp/DoorUnlocker/Firmware/DoorUnlockerXiao-dfu.zip
```

Then run the repeatable physical-device verifier:

```sh
./script/verify_ios_ota.sh --wireless-only --target <new-version>
```

The wireless verifier installs the iPhone app, launches the bundled-firmware debug update flow, and waits for a version-specific iPhone Darwin notification that is posted only after the app receives `firmware_version:<target>` from the controller over BLE after DFU. With `--wireless-only`, the script refuses to start if the controller USB-C serial port is visible. The controller should not be plugged into USB-C for this proof; the iPhone can stay connected to the Mac for app installation and automation.

Each verifier run writes a persistent telemetry summary to `docs/ota-last-run.json` and detailed launch/notification logs under `docs/ota-telemetry/`. The success report includes the target firmware, elapsed seconds, package byte count, package hashes, whether it was wireless-only, and the exact Darwin notification that proved the app saw the post-update firmware version over BLE.

To terminate the iPhone app during a real upload and prove journal recovery, run a new-version wireless test such as:

```sh
RUN_ID=<run-id> INTERRUPT_AT_PROGRESS=30 \
  ./script/verify_ios_ota.sh --wireless-only --target <new-version>
```

The verifier kills the app process after observing the requested progress, relaunches it without requesting another update, and only passes after the relaunched app receives the target firmware version over BLE. Use `script/summarize_ota_timing.py` to turn a captured app console log into structured timing JSON.

A physical factory-bootloader power-loss baseline is recorded in [`docs/ota-factory-power-loss-baseline.json`](docs/ota-factory-power-loss-baseline.json). Cutting controller power during the factory single-bank upload left the XIAO recoverable through USB UF2, and all pairings/settings survived, but the factory bootloader did not advertise BLE after power returned. The production gate therefore requires the signed dual-bank candidate to pass the same physical campaign before it can be called production-ready.

The OTA verifier hard-blocks another physical mid-update power cut unless an exact installed bootloader proof and explicit recovery conditions are present. This keeps routine testing non-destructive while still allowing app termination and Bluetooth transport-loss recovery tests. `script/simulate_dual_bank_power_loss.py` checks every whole transfer percentage plus every modeled erase page, copied word, settings write, journal write/clear boundary, and corrupt-image path.

Use `INTERRUPT_MODE=bluetooth-loss` to force a one-shot DFU transport disconnect at the requested percentage and prove bounded automatic retry without terminating the app:

```sh
RUN_ID=<run-id> INTERRUPT_MODE=bluetooth-loss INTERRUPT_AT_PROGRESS=40 \
  ./script/verify_ios_ota.sh --wireless-only --allow-current
```

For Mac OTA testing, build the package and send it through the Mac app/CLI flow:

```sh
./script/flash_xiao_uf2.sh --build-only
./script/build_and_run.sh --install
./dist/door-unlocker firmware-proof dist/DoorUnlockerXiao-signed-dfu.zip <new-version>
```

`firmware-proof` sends the update request to the running Mac app, waits for the app to receive the expected `firmware_version` over BLE after DFU, then prints `verified_over=ble`. Use plain `firmware ZIP_PATH` for an interactive app-driven update when you do not need an automated proof.

The XIAO bootloader is separate from Door Unlocker firmware. The repository pins Adafruit nRF52 Bootloader `0.11.0` to audited upstream commit `c67f0bcf0fa8e841426335b1bbde91cda6ca1f50` and builds it for `xiao_nrf52840_ble_sense` with `DUALBANK_FW=1`, `SIGNED_FW=1`, upstream Nordic bank activation, and invalid-app BLE recovery. An interrupted transfer retains the previous application in bank 0. Intentional double reset enters USB recovery: `XIAO-SENSE` mounts read-only, `INFO_UF2.TXT` reports the exact Door Unlocker recovery build ID, and signed recovery is delivered through USB CDC serial DFU. Routine application ZIP and UF2 packages are gated to the application range and cannot replace the bootloader. The build also pins ATT MTU `247`, DFU payloads up to `244` bytes, data-length extension, automatic 2 Mbps PHY negotiation, a fixed Apple-compatible `15ms` connection interval, connection-event extension, and accelerated flash writes. `script/build_secure_bootloader.sh` reproduces the candidate from the checked-in public key; the private key is required only to sign updates and remains outside Git.

`script/flash_xiao_uf2.sh --build-only` creates both package envelopes when the private key is present. `script/check_ota_bootloader_contract.py` requires byte-identical application payloads, verifies the signed package against the checked-in public key, and validates both migration-UF2 and normal application-UF2 address ranges. The candidate is installed and exact-build USB recovery is proven, but it is **not** production-proven until the remaining content-bound OTA interruption, power-loss, and unsigned-rejection campaign passes.

Capture the normal controller baseline, double-reset it, then exercise signed USB recovery:

```sh
python3 script/verify_usb_recovery.py --capture-baseline
# Physically double-press reset; XIAO-SENSE must mount.
python3 script/verify_usb_recovery.py --exercise --write-proof
```

The proof requires the expected board and bootloader build IDs, one matching USB hardware serial, a read-only mount with rejected writes, successful signed serial DFU, the expected recovered firmware version, and preserved pair count, lock name, timeout, and servo angles.

Every firmware release reruns the application-only ZIP and UF2 range gates. Every beta and stable tag also requires the exact hardware-proven USB recovery build and exact application OTA evidence. A release cannot silently remove this escape hatch: changing the bootloader requires a separately signed bootloader package and invalidates the content-bound recovery proof until the new build is physically exercised.

The operator-facing failure matrix and exact recovery commands are maintained in [docs/firmware-recovery-runbook.md](docs/firmware-recovery-runbook.md).

Prepare the candidate without modifying hardware using `script/install_secure_bootloader.sh`. The explicit `--install --confirm-jlink-recovery` mode copies the special one-time UF2 migration image only when the existing XIAO bootloader volume is mounted and the operator confirms an SWD unbrick path. Routine updates continue to use signed BLE DFU packages, not the migration image.

`./script/build_and_run.sh --install` also creates `dist/door-unlocker`, a local command-line tool:

```sh
./dist/door-unlocker status
./dist/door-unlocker unlock
./dist/door-unlocker lock
./dist/door-unlocker toggle
./dist/door-unlocker timeout 30
./dist/door-unlocker angles 95 20
./dist/door-unlocker pairs
./dist/door-unlocker rename 1 "My iPhone"
```

Use `./dist/door-unlocker --help` for the full command list. The CLI auto-detects the XIAO serial port by default and also accepts `--port /dev/cu.usbmodemXXXX`.
When the Mac app is already running, `lock`, `unlock`, `toggle`, `timeout`, and `angles` are handed to the app locally so the CLI does not compete with the app for the USB-C serial stream.

## Roadmap

- Controller/app usage stats: track values such as daily unlock counts and recent lock/unlock history. Keep this local-first and privacy-preserving, with the controller as the source of truth where practical.
- Per-device access roles: let owner/admin devices approve new devices wirelessly while standard trusted devices can only lock/unlock or use selected settings.
- Power-optimized hardware pass: replace prototype power modules with the optimal component stack documented in [docs/optimal-components.md](docs/optimal-components.md), then remeasure idle current, servo hold current, charge recovery, and enclosure heat.
- Matter/HomeKit evaluation after moving beyond the current BLE-only controller path.
- Universal handle/turn-button actuator support, tamper/weather improvements, and later camera-assisted installation guidance.

The complete phased hardware/product roadmap is maintained in the [interactive project page](https://bt1142msstate.github.io/door-unlocker/).

## Security And Safety

This project intentionally avoids publishing a command secret. The iPhone and Mac apps sign each wireless command with a locally generated private key, and the XIAO verifies the signature with the paired public key. Each accepted `v3` command also consumes a random, connection-private controller nonce, which prevents a captured command packet from being replayed.

The application protocol authenticates commands; it does not claim end-to-end confidentiality for BLE advertisements or shared state notifications. The current bootloader enforces the project P-256 signing key and its exact USB recovery build identity is physically proven, but the full interruption and fault-injection campaign remains production-unproven. Physical possession and USB-C remain a recovery/admin boundary, and this prototype has not received an external security audit.

BLE pairing is locked unless pairing mode is enabled by USB-C or by a signed command from an already trusted device. A new device can submit a pairing request only while pairing is open, and it is not trusted until an already trusted iPhone/Mac or USB-C operator approves the 4-digit code shown on the new device. Pairing mode turns itself off after approval. If every trusted app key is lost, connect over USB-C, send `pair on`, and pair a replacement device. Use `pairs remove N`, `app remove N`, or `pairs clear` over USB-C if you need to remove trusted devices. A future access-role model should separate owner/admin devices from standard lock/unlock-only devices.

For anything beyond desk testing, review the mechanical mount, fail-safe behavior, battery handling, apartment rules, fire-safety requirements, and lock/egress requirements before use.

## License

MIT License. See [LICENSE](LICENSE).
