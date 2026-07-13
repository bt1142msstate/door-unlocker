# OTA Firmware Update Speed And Recovery Plan

Date: 2026-07-12

## Current Evidence

- Controller firmware source: `0.1.26`
- Signed application payload: `134,452` bytes (`134,444` bytes reported by the Arduino sketch build before DFU packaging)
- Factory package: `DoorUnlockerXiao-dfu.zip`, DFU manifest `0.5` with CRC16
- Signed candidate package: `DoorUnlockerXiao-signed-dfu.zip`, DFU manifest `0.8` with P-256 ECDSA
- Installed factory bootloader observed from `INFO_UF2.TXT`: Adafruit/Seeed `0.11.0`, S140 `7.3.0`
- Installed wireless update protocol observed by Nordic DFU: Legacy DFU init-packet format `0.8`
- Latest optimized iPhone BLE proof: `19s` end to end, with controller USB-C attached only as a recovery/power anchor
- Measured upload portion of that proof: `7.05s` (`~19 KB/s` average)
- Previous controller-unplugged proof: `92s` end to end / `82.68s` upload
- Installed factory bootloader negotiated Legacy DFU payload: `244` bytes
- Shared production tuning: PRN `8`, object-preparation delay `0.4s`

The earlier `92s` proof used a trusted iPhone, a signed BLE OTA-entry command, no controller USB connection, DFU upload, reboot, secure reconnection, and a post-reboot `firmware_version:0.1.26` notification. The optimized `19s` proof used the same BLE entry/upload/verification path while controller USB-C remained attached only as a recovery anchor; no USB recovery command was used. A final optimized controller-unplugged run is still required. Neither proof establishes atomic rollback or signed-package enforcement in the installed factory bootloader.

On July 12, the controller was recovered from its UF2 bootloader to application `0.1.26`. The protected controller state remained intact: two trusted devices, lock name, timeout, and servo angles all survived. The custom signed/dual-bank candidate was not installed because no J-Link/SWD recovery probe was attached.

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

This currently proves the signed package and candidate build. It deliberately reports these hardware claims as `NOT PROVEN`:

- exact candidate installed on the controller
- dual-bank rollback under physical power loss
- unsigned application rejection by the installed bootloader

Production mode remains closed until all three are backed by `docs/ota-bootloader-installed-proof.json`:

```sh
python3 script/check_ota_bootloader_contract.py --require-production
```

## Measured Throughput

The original `82.68s` upload for roughly `134 KB` was about `1.6 KB/s`. The optimized iPhone run transferred the same application in `7.05s`, averaging about `19 KB/s`.

Upstream NordicDFU `4.16.0` hardcodes Legacy DFU packets to `20` bytes, so the project vendors it with a focused compatibility patch. Initial 244-byte physical runs uploaded in `9.54-13.89s` but failed final CRC because the factory `AdaDFU` bootloader was given an ECDSA init packet it does not understand. The same binary wrapped in AdaDFU's legacy CRC16 package uploaded in `7.05s` and returned `Validate Firmware: Success`. The client now enables 244-byte writes only for known `AdaDFU` and `DoorDFU` names; unknown bootloaders remain at 20 bytes. Package selection happens after discovery: `AdaDFU` gets CRC16 and `DoorDFU` gets ECDSA.

Factory PRN remains `8`. On the Mac, physical PRN `0`, `8`, and `16` runs all validated, but `8` was fastest of those runs at roughly `5 KB/s`; the bottleneck is macOS/factory-bootloader scheduling rather than payload size. `DoorDFU` uses PRN `1` until its larger-payload dual-bank behavior is physically proven. The configured `0.4s` object-preparation delay is ignored by Legacy DFU.

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

Run the power-loss mode in a terminal. At the threshold it prompts the operator to remove controller power for at least two seconds, restore it, and confirm. The app remains alive so the resulting trace proves controller-side recovery rather than app relaunch behavior.

The verifier installs the app, starts a real OTA, watches structured `DUFirmware` events, terminates the process at the requested progress, and relaunches without requesting another update. It passes only after the relaunched app receives the target firmware version over BLE. Physical 30% and 80% app-termination runs both passed; each restarted the factory Legacy DFU transaction cleanly, validated, and cleared the journal.

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
