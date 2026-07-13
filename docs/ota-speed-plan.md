# OTA Firmware Update Engineering Record

Last updated: 2026-07-13

This document preserves benchmark and fault-recovery history. For release decisions, use [`ota-completion-audit.md`](ota-completion-audit.md), [`quality-suite.md`](quality-suite.md), and the current release-readiness report. Old firmware versions below are evidence from specific tests, not setup instructions.

## Current Evidence

- Controller firmware source: `0.1.30`
- Signed application payload: `134,452` bytes (`134,444` bytes reported by the Arduino sketch build before DFU packaging)
- Factory package: `DoorUnlockerXiao-dfu.zip`, DFU manifest `0.5` with CRC16
- Signed candidate package: `DoorUnlockerXiao-signed-dfu.zip`, DFU manifest `0.8` with P-256 ECDSA
- Installed bootloader: project-signed Adafruit nRF52 Bootloader `0.11.0`, dual-bank, S140 `7.3.0`, advertising `DoorDFU`; the latest OTA session sent the release-candidate artifact with SHA-256 `6e00ea51eefd81d90429e45ed33c3d2543e19a30147e4f8ae3bfcdd46eb9a5f9`
- Production-proof status: application and bootloader OTA behavior has been demonstrated, but the content-bound installed-proof file still refers to an older artifact. Production promotion remains blocked until the exact current artifact completes the full interruption and unsigned-rejection campaign.
- Installed wireless update protocol: Legacy DFU init-packet format `0.8` with P-256 ECDSA enforcement
- Latest fixed-15 iPhone wireless-only proof: three consecutive PRN `9` uploads at `15,149`, `16,300`, and `17,170 B/s`; two later unattended-phone transfers measured `11,535` and `10,201 B/s`
- Latest Mac wireless-only comparison: PRN `9` sustained about `6 KB/s`; PRN `0`, `4`, and `32` each regressed to about `3-4 KB/s`
- Installed signed bootloader negotiated Legacy DFU payload: `244` bytes
- Measured release tuning: iPhone and Mac PRN `9`, object-preparation delay `0.3s`, fixed `15ms` interval, automatic PHY, 16 HCI receive buffers, 18 flash-queue entries, and flash local latency `50`

The current iPhone and Mac path uses a trusted device, a signed BLE OTA-entry command, no controller USB connection, the signed `DoorDFU` package, reboot, secure reconnection, and a post-reboot firmware-version notification. The earlier factory-bootloader `19s` proof remains useful as a historical throughput baseline only.

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

## Product OTA Scope

Routine product software changes must not require opening the enclosure or connecting controller USB-C. A trusted iPhone or Mac must be able to deliver:

- signed Door Unlocker application firmware;
- signed bootloader replacements, including transport and recovery-policy changes;
- combined bootloader/application packages when a coordinated migration requires them.

Nordic DFU also defines SoftDevice-capable packages, but this project has not yet physically qualified a signed S140 replacement or signing-key rotation on the exact controller. Those are explicit remaining qualification cases, not established production capabilities. Hardware changes, a completely nonresponsive radio, or corruption below the bootloader remain physical-service cases. USB-C and SWD therefore remain recovery fallbacks, not the normal update path.

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
- transactional activation journal at `0xE9000`, the otherwise-unused page between bank 1 and reserved application data
- bank 0 is changed only after the signed/hash-verified bank-1 image and its journal are durable
- boot-time activation is idempotent; erase, copy, settings-write, or journal-clear interruption resumes safely
- ATT MTU support raised from the legacy `23`-byte path to upstream's `247`
- maximum Legacy DFU write payload `244` bytes, data-length extension, and automatic 2 Mbps PHY negotiation
- fixed `15ms` connection interval, connection-event extension, and accelerated flash-write pacing

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

`docs/ota-bootloader-installed-proof.json` records the exact installed artifact rather than accepting a matching version string. A changed bootloader hash invalidates that proof until signed-package acceptance, unsigned rejection, preserved state, both clients, and the physical interruption campaign are rerun. Production mode remains closed while any required exact-device evidence is missing:

```sh
python3 script/check_ota_bootloader_contract.py --require-production
```

## Measured Throughput

The original `82.68s` upload for roughly `134 KB` was about `1.6 KB/s`. The optimized iPhone run transferred the same application in `7.29s`, averaging about `19 KB/s`.

Upstream NordicDFU `4.16.0` hardcodes Legacy DFU packets to `20` bytes, so the project vendors it with a focused compatibility patch. Initial 244-byte physical runs uploaded in `9.54-13.89s` but failed final CRC because the factory `AdaDFU` bootloader was given an ECDSA init packet it does not understand. The same binary wrapped in AdaDFU's legacy CRC16 package uploaded in `7.05s` and returned `Validate Firmware: Success`. The client now enables 244-byte writes only for known `AdaDFU` and `DoorDFU` names; unknown bootloaders remain at 20 bytes. Package selection happens after discovery: `AdaDFU` gets CRC16 and `DoorDFU` gets ECDSA.

On July 13, an exact-hardware iPhone matrix tested PRN `0`, `4`, `6`, `8`, `9`, `10`, `11`, `12`, `14`, `16`, `24`, and `32` with the same signed `134,452`-byte package. Every supported setting completed and passed post-reboot BLE version verification. PRN `9` was the clear candidate: three consecutive uploads completed in `5.61s`, `6.12s`, and `6.36s` (median `6.12s`, best `5.61s`, about `22.0 KB/s` median payload throughput). PRN `8` took `6.63-7.02s` in the immediately comparable runs; PRN `10-32` were slower and more variable. PRN `0`, which relies on CoreBluetooth backpressure without target receipt notifications, passed but took `9.54s`.

A later exact-hardware rerun on application `0.1.29` exposed the installed bootloader's variable connection interval: PRN `0` uploaded in `12.12s` at `11,962 B/s`, while PRN `32` uploaded in `12.06s` at `11,389 B/s`. Since opposite flow-control settings converged on the same payload time while earlier 15 ms selections reached `22-24 KB/s`, the remaining throughput limiter was the installed bootloader's 15-30 ms interval negotiation, not iPhone sender pacing.

The signed fixed-15 ms bootloader was then installed wirelessly from the trusted Mac app. Its bootloader-only package identifies the XIAO nRF52840 hardware revision as `52840`; this matters because the Adafruit bootloader rejects bootloader or SoftDevice images for any other revision before accepting image bytes. After the wireless bootloader migration, three iPhone PRN `9` uploads passed post-reboot BLE verification at `15,149`, `16,300`, and `17,170 B/s` (median `16,300 B/s`). A three-run PRN `8` comparison was slower at a `14,282 B/s` median, so PRN `9` remains the production profile.

A longer same-version campaign added two successful PRN `9` transfers at `11,535` and `10,201 B/s`. Its third attempt never entered DFU because the unattended physical iPhone had locked and suspended the foreground debug launch; the report contains no bootloader-discovery or transfer event and therefore is an initiation-harness failure, not a throughput sample. Across the five actual fixed-15 PRN `9` transfers, the median is `15,149 B/s`.

Exact-hardware bootloader variants isolated the remaining safe tuning choices:

- forcing 2 Mbps PHY regressed three iPhone transfers to an `11,306 B/s` median; automatic PHY remains faster;
- fixing the connection interval at `30ms` regressed three iPhone transfers to an `11,137 B/s` median; fixed `15ms` remains faster;
- setting flash local latency to `0` reduced the Mac PRN `9` path from roughly `6 KB/s` to roughly `4 KB/s`;
- increasing HCI/flash queues from `16/18` to `32/34` reduced the Mac PRN `9` path to roughly `3-4 KB/s`;
- Mac PRN `0`, `4`, and `32` each measured roughly `3-4 KB/s`, while PRN `9` measured roughly `6 KB/s`.

Every bootloader variant was installed as a signed bootloader-only package over BLE, exercised with a signed application package, and then replaced wirelessly. The controller is back on the exact release-candidate bootloader package: fixed `15ms`, automatic PHY, flash local latency `50`, and `16/18` queues. USB-C was not used for these migrations.

`script/benchmark_ios_ota_matrix.sh` now applies a `10,000 B/s` gate by default. The summarizer extracts the final NordicDFU average payload rate from every successful run and requires every run, not only the median or best sample, to meet the floor. Override `MINIMUM_THROUGHPUT_BPS` only for diagnostic matrices; production evidence must retain the default.

An experimental hybrid that mixed CoreBluetooth queue flow control with Nordic PRN flow control failed (`9,760` bytes sent while the controller reported `1,952` received). It was reverted byte-for-byte and is prohibited: a transfer must use exactly one flow-control authority. The supported PRN ceiling remains `32`; pushing the receipt window above that is not justified because settings `10-32` already regressed and Nordic warns that oversized windows can overflow a target whose flash cannot keep up. iOS and macOS now share the measured PRN `9` default. The configured `0.3s` object-preparation delay is ignored by Legacy DFU.

The PRN `9` candidate also passed two exact-hardware recovery runs on July 13. A forced Bluetooth transport loss at 40% recovered and verified over BLE in `38s`. Terminating the iPhone updater process at 50%, relaunching it, and resuming from the durable journal recovered and verified over BLE in `40s`. These timings include interruption and recovery; they are not clean-upload throughput samples.

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

`script/simulate_dual_bank_power_loss.py` models cuts at every whole transfer percentage and every activation erase page, copied word, settings commit, journal commit/clear boundary, reboot boundary, and corrupt-image path. For the current payload that is 100 transfer points and 33,680 activation points. It verifies that each state either boots the untouched previous firmware, resumes from immutable bank 1, or boots the CRC-verified replacement. Simulation complements rather than replaces attended exact-hardware power-loss tests.

Reusable attended presets are available for other recovery scripts:

```sh
./script/physical_handoff.sh --preset connect-usb
./script/physical_handoff.sh --preset return-to-battery
./script/physical_handoff.sh --preset reset-once
./script/physical_handoff.sh --preset reset-twice
```

The helper process blocks the caller until the confirmation button is pressed, so the waiting test resumes automatically without polling chat or exposing a terminal workflow.

The verifier installs the app, starts a real OTA, watches structured `DUFirmware` events, and injects the requested failure. It passes only after the app receives the target firmware version over BLE. Signed `DoorDFU` app-termination runs at 30% and 80% passed in `77s` and `96s`; a 40% Bluetooth transport loss recovered and verified in `81s`. The earlier factory 30% controller-power-loss failure remains the baseline superseded by the signed candidate's successful 30% and 80% battery cuts.

The first signed dual-bank candidate was installed on July 12 and behaviorally identified by its fresh `DoorDFU` advertisement and successful P-256 package validation. A CoreBluetooth cache issue initially presented the old `AdaDFU` peripheral name; the shared iOS/macOS manager now prefers the live advertisement name. Real battery cuts at 30% and 80% then passed without USB recovery: the previous `0.1.26` firmware booted, reauthenticated, and was verified over BLE in `62s` and `73s`, respectively. Those runs remain useful transfer-interruption evidence, but they do not prove the later transactional activation artifact because its bootloader hash differs.

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

### 2026-07-13 migration sequence and final result

- Firmware `0.1.28` added incremental inactive-bank preparation and the `ota_staging_ready` snapshot field. The first installed bootloader still imposed a 3.49-second start delay and initially rejected two bootloader-only packages during initialization.
- Correcting the bootloader package hardware revision to the XIAO nRF52840 value `52840` resolved that rejection. Signed bootloader-only packages then installed successfully over BLE from a trusted client.
- The fixed-15, forced-2-Mbps, fixed-30, flash-latency, and queue-depth variants were all installed and replaced wirelessly. The final controller was returned wirelessly to the release profile: fixed `15ms`, automatic PHY, PRN `9`, flash local latency `50`, and `16/18` queues.
- Terminal integrity or compatibility failures clear the saved transaction in both clients, preventing a rejected package from restarting after normal firmware reconnects.
