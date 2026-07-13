# OTA Firmware Update Speed And Recovery Plan

Date: 2026-07-12

## Current Evidence

- Controller firmware source: `0.1.26`
- Signed application payload: `134,452` bytes (`134,444` bytes reported by the Arduino sketch build before DFU packaging)
- Factory package: `DoorUnlockerXiao-dfu.zip`, DFU manifest `0.5` with CRC16
- Signed candidate package: `DoorUnlockerXiao-signed-dfu.zip`, DFU manifest `0.8` with P-256 ECDSA
- Installed bootloader: project-signed Adafruit nRF52 Bootloader `0.11.0`, dual-bank, S140 `7.3.0`, advertising `DoorDFU`
- Installed wireless update protocol: Legacy DFU init-packet format `0.8` with P-256 ECDSA enforcement
- Latest optimized iPhone wireless-only proof: `25s` end to end / `8.94s` upload with PRN `8`
- Latest optimized Mac wireless-only proof: `43s` end to end / `26s` upload with PRN `16`
- Installed signed bootloader negotiated Legacy DFU payload: `244` bytes
- Measured production tuning: iPhone PRN `8`, Mac PRN `16`, object-preparation delay `0.4s`

The current iPhone and Mac proofs use a trusted device, a signed BLE OTA-entry command, no controller USB connection, the signed `DoorDFU` package, reboot, secure reconnection, and a post-reboot `firmware_version:0.1.26` notification. The earlier factory-bootloader `19s` proof remains useful as a historical throughput baseline only.

On July 12, a real controller-power-loss test removed battery power after an iPhone transfer crossed 30 percent. The factory single-bank bootloader did not advertise `AdaDFU` after power returned; it flashed red in USB DFU mode while the relaunched iPhone correctly retried its journal three times. USB UF2 recovery restored application `0.1.26`. The protected controller state remained intact: two trusted devices, lock name `College View Door`, 30-second timeout, and `95`/`20` servo angles all survived. The machine-readable baseline is `docs/ota-factory-power-loss-baseline.json`.

That failure became an explicit architectural gate. The signed dual-bank candidate was installed with the operator's explicit no-SWD risk acceptance. It stages the replacement while the old application remains bootable, defaults an invalid application to BLE `DoorDFU`, and preserves a deliberate reset-button double press as a recovery path. Real battery cuts at 30% and 80% both returned to normal firmware `0.1.26` without USB recovery and preserved all trusted devices and settings.

## Recovery Design

iOS and macOS share a durable firmware-update journal. It records the staged package, byte count, SHA-256 fingerprint, target version, phase, attempt count, last progress, and failure reason. The transaction is retained until normal firmware reports the expected version.

After an app relaunch or interrupted transport, recovery is normal-mode first:

1. Probe the normal Door Unlocker service/name for four seconds.
2. If expected firmware responds, verify it and clear the journal.
3. If old firmware responds, use the trusted secure command to re-enter DFU and restart cleanly.
4. If normal firmware does not respond, scan for the Nordic/Adafruit bootloader and restart the Legacy DFU transfer from the saved package.
5. Retry transient Bluetooth/app/power interruptions at most three upload attempts. Treat CRC, signature, invalid-object, unsupported-package, and package-integrity errors as terminal until a different package is supplied.

The normal-first order matters because the legacy bootloader may reboot the previous valid application when its DFU central disappears. Searching only for the bootloader would leave both apps stuck even though healthy normal firmware had returned.

The Mac stages its ZIP under Application Support with same-volume replacement. Neither app relies on a temporary file surviving relaunch.

## Signed Dual-Bank Candidate

`script/build_secure_bootloader.sh` reproducibly builds Adafruit nRF52 Bootloader `0.11.0` for the exact `xiao_nrf52840_ble_sense` board from the checked-in public key, without requiring the private application-signing key, with:

- `DUALBANK_FW=1`
- `SIGNED_FW=1`
- invalid applications default to BLE `DoorDFU`
- intentional reset-button double press remains USB UF2 recovery
- project P-256 public key compiled into the bootloader
- unsigned UF2 recovery disabled
- S140 `7.3.0` / firmware ID `0x0123`, matching the XIAO application build
- `397,312`-byte maximum dual-bank application size; the current `134,452`-byte payload fits with substantial margin
- ATT MTU support raised from the legacy `23`-byte path to upstream's `247`
- maximum Legacy DFU write payload `244` bytes, data-length extension, and automatic 2 Mbps PHY negotiation
- `15-30ms` connection intervals, connection-event extension, and accelerated flash-write pacing

The public key and candidate metadata are checked in at:

- `docs/firmware-signing-public-key.pem`
- `docs/firmware-signing-public-key.json`

The private key is intentionally outside Git:

```text
~/Library/Application Support/Door Unlocker/FirmwareSigning/firmware-signing-key.pem
```

Back it up in a protected location before migrating hardware. A controller enforcing this key cannot accept future application images signed by a replacement key.

The generated bootloader artifact is ignored under `dist/bootloader/`. Its expected SHA-256 is recorded in the public manifest. Rebuild it with:

```sh
./script/build_secure_bootloader.sh
```

`script/flash_xiao_uf2.sh --build-only` always creates the factory CRC16 package and, when the private key exists, also creates the signed candidate package. The structural gate requires their application binaries to be byte-identical and verifies the signed package's P-256 ECDSA signature with OpenSSL:

```sh
python3 script/check_ota_bootloader_contract.py
```

The same gate parses the one-time migration UF2 block by block. It verifies UF2 structure, nRF52 family ID, artifact hash, and the exact recorded address ranges. It fails if any block touches S140, the application, or the reserved Door Unlocker pairing/settings region. It also checks that the reproducible source and public manifest retain the exact high-throughput BLE profile above. A full quality-suite run rebuilds the candidate and requires that reproducibility contract to pass.

`docs/ota-bootloader-installed-proof.json` now proves the exact candidate hash, signed-package acceptance, unsigned factory-envelope rejection, preserved controller state, iPhone and Mac wireless updates, app-termination recovery, Bluetooth-loss recovery, and physical upload cuts at 30% and 80%. Production mode remains closed only on the deterministic erase and post-validation physical interruption cases:

```sh
python3 script/check_ota_bootloader_contract.py --require-production
```

## Measured Throughput

The original `82.68s` upload for roughly `134 KB` was about `1.6 KB/s`. The optimized iPhone run transferred the same application in `7.29s`, averaging about `19 KB/s`.

Upstream NordicDFU `4.16.0` hardcodes Legacy DFU packets to `20` bytes, so the project vendors it with a focused compatibility patch. Initial 244-byte physical runs uploaded in `9.54-13.89s` but failed final CRC because the factory `AdaDFU` bootloader was given an ECDSA init packet it does not understand. The same binary wrapped in AdaDFU's legacy CRC16 package uploaded in `7.05s` and returned `Validate Firmware: Success`. The client now enables 244-byte writes only for known `AdaDFU` and `DoorDFU` names; unknown bootloaders remain at 20 bytes. Package selection happens after discovery: `AdaDFU` gets CRC16 and `DoorDFU` gets ECDSA.

Factory and signed `DoorDFU` updates use PRN `8` on iPhone. A signed PRN `16` iPhone comparison produced essentially the same result (`8.85s` versus `8.94s` upload), so PRN `8` remains the better feedback/stability tradeoff. Mac keeps its measured PRN `16` default; on installed `DoorDFU` this reduced upload time from `51s` at PRN `1` to `26s`. The configured `0.4s` object-preparation delay is ignored by Legacy DFU.

## Repeatable Tests

Clean iPhone wireless-only proof:

```sh
RUN_ID=<run-id> \
  ./script/verify_ios_ota.sh --wireless-only --target <new-version>
```

App-termination injection at 30 percent:

```sh
RUN_ID=<run-id> INTERRUPT_AT_PROGRESS=30 \
  ./script/verify_ios_ota.sh --wireless-only --target <new-version>
```

Interactive controller-power-loss injection at 30 percent:

```sh
RUN_ID=<run-id> INTERRUPT_MODE=controller-power-loss INTERRUPT_AT_PROGRESS=30 \
  ./script/verify_ios_ota.sh --wireless-only --target <new-version>
```

The verifier normally refuses this physical mode unless the exact signed dual-bank bootloader has an installed proof, its recovery artifact hash matches, and an SWD recovery path is recorded as available. An explicit `--accept-no-swd-recovery-risk` override exists only for attended testing after the operator accepts the replacement-hardware risk. At the threshold it terminates the updater to freeze a genuinely partial image and opens the reusable SwiftUI physical-handoff assistant. **Start countdown** speaks the 3-2-1 instructions; **Power restored** returns control directly to the waiting verifier after the operator has removed controller power for at least two seconds and restored it. The same assistant accepts direct, spoken USB-C and one-/two-press reset requests without exposing a console. A terminal fallback remains available with `PHYSICAL_HANDOFF_MODE=terminal`.

`script/simulate_dual_bank_power_loss.py` models a cut at every whole percentage from 0 through 99. It verifies that the current application-sized payload fits the dedicated staging bank, that no single-bank fallback is allowed, and that pre-validation interruption selects the previous firmware. This simulation does not replace the attended activation-copy test; that final, short phase remains a physical production gate.

Reusable attended presets are available for other recovery scripts:

```sh
./script/physical_handoff.sh --preset connect-usb
./script/physical_handoff.sh --preset return-to-battery
./script/physical_handoff.sh --preset reset-once
./script/physical_handoff.sh --preset reset-twice
```

The helper process blocks the caller until the confirmation button is pressed, so the waiting test resumes automatically without polling chat or exposing a terminal workflow.

The verifier installs the app, starts a real OTA, watches structured `DUFirmware` events, and injects the requested failure. It passes only after the app receives the target firmware version over BLE. Signed `DoorDFU` app-termination runs at 30% and 80% passed in `77s` and `96s`; a 40% Bluetooth transport loss recovered and verified in `81s`. The earlier factory 30% controller-power-loss failure remains the baseline superseded by the signed candidate's successful 30% and 80% battery cuts.

The signed dual-bank candidate was installed on July 12 and behaviorally identified by its fresh `DoorDFU` advertisement and successful P-256 package validation. A CoreBluetooth cache issue initially presented the old `AdaDFU` peripheral name; the shared iOS/macOS manager now prefers the live advertisement name. Real battery cuts at 30% and 80% then passed without USB recovery: the previous `0.1.26` firmware booted, reauthenticated, and was verified over BLE in `62s` and `73s`, respectively.

Summarize a console trace:

```sh
python3 script/summarize_ota_timing.py \
  docs/ota-telemetry/<run>-app-console.log \
  --output docs/ota-telemetry/<run>-timing.json
```

The same-version `--allow-current` mode is a script smoke test, not a release proof. A valid release proof must use a newly bumped firmware version so a stale installed image cannot satisfy the verifier.

## Physical Fault Campaign

The signed bootloader migration and power-loss campaign must be attended with USB-C/J-Link recovery available. Use one freshly bumped package per clean proof and retain all telemetry.

Required cases:

1. Clean iPhone wireless update.
2. App termination during scan/connection.
3. App termination around 30 percent and 80 percent upload.
4. Bluetooth loss during upload, followed by reconnect.
5. Controller power loss during erase/object preparation.
6. Controller power loss around 30 percent and 80 percent upload.
7. Power loss after validation but before first verified normal boot.
8. Corrupt or wrong-signature package rejection while old firmware remains bootable.
9. Valid signed package success after the rejection test.
10. One clean Mac wireless update using the same shared DFU implementation.

Every passed case must preserve trusted-device keys, lock name, timeout, servo angles, and a bootable previous or new application. Failed transfer attempts must not clear the journal or masquerade as successful verification.

## Release Gates

`python3 script/quality_suite.py` always verifies the signed package and candidate metadata. `python3 script/quality_suite.py --firmware-release` additionally requires:

1. The installed-proof file matches the exact bootloader artifact SHA-256, public key ID, and bootloader version.
2. Physical dual-bank rollback has passed.
3. An unsigned package was rejected.
4. The exact release DFU package passed wireless BLE entry/upload/reboot/version verification.
5. App-termination recovery passed on iPhone.
6. A clean Mac update passed with the same shared transport settings.
7. Pairings and controller settings survived the campaign.

Do not mark this goal complete or publish the bootloader migration as production-ready until those gates pass.

## References

- [Adafruit nRF52 Bootloader releases](https://github.com/adafruit/Adafruit_nRF52_Bootloader/releases)
- [Adafruit nRF52 Bootloader build/security documentation](https://github.com/adafruit/Adafruit_nRF52_Bootloader)
- [Nordic iOS DFU Library](https://github.com/NordicSemiconductor/IOS-DFU-Library)
- [Apple Bluetooth accessory design guidance](https://developer.apple.com/accessories/Accessory-Design-Guidelines.pdf)
- [Nordic S140 BLE throughput documentation](https://docs.nordicsemi.com/bundle/sds_s140/page/SDS/s1xx/ble_data_throughput/ble_data_throughput.html)
