# OTA Firmware Update Speed Plan

Date: 2026-07-08

## Current Baseline

- Stable firmware: `0.1.0`
- DFU package: `dist/DoorUnlockerXiao-dfu.zip`
- Package size: `130,219` bytes
- Application payload: `129,344` bytes
- Fastest verified iPhone wireless proof: `94s`, verified over BLE by post-DFU `firmware_version:0.1.0`
- Latest one-run iPhone wireless benchmark: stable PRN `8` / object delay `0.4s` completed in `113s`; PRN `8` / object delay `0.3s` completed in `114s`
- Current production DFU tuning: PRN `8`, object-prep delay `0.4s`, scan timeout `18s`, connection timeout `20s`

The measured end-to-end throughput ranges from about `1.12 KB/s` to `1.35 KB/s` using the full zip size. This includes app launch, secure OTA-entry command, bootloader scan, Nordic DFU setup, upload, reboot, reconnect, and firmware-version verification, so the raw upload throughput is higher than the end-to-end number.

## Primary Constraints

1. The project uses Nordic Secure DFU through `NordicDFU` `4.16.0` on iOS and macOS. Nordic documents that PRNs can be disabled on modern iOS/macOS, but also warns that slow flash handling can fail or become very slow without PRNs.
2. Nordic documents Secure DFU object-prep delay as a flash-preparation guard. For SDK 15-17 style bootloaders, the documented safe range is `0.3s` to `0.4s`; too little delay can trigger PRN `1` fallback, making DFU very slow.
3. The Adafruit nRF52 bootloader README states that OTA PRN must be `8` or less or the bootloader can run out of memory. That makes PRN `8` the highest safe production value for the current XIAO/Adafruit bootloader path.
4. Apple's BLE guidance requires accessory connection parameters that preserve discovery and connection stability. It also notes that some Apple devices scale a `15ms` fixed interval to `30ms`, so firmware-side connection-interval forcing is not a reliable path to instant speed.
5. Nordic's S140 throughput tables show that BLE can move far more data than this project currently sees in ideal conditions, especially with larger ATT MTU and data length. The current bottleneck is therefore the bootloader/client DFU path and flash-write pacing, not the nRF52840 radio alone.

## What Is Already Maxed Safely

- PRN is already at `8`, the highest value documented as safe for Adafruit nRF52 OTA.
- The firmware build uses `-Os`, which reduced the package to the current `127 KB` zip without changing behavior.
- Both iPhone and Mac apps now consume the same shared `DoorFirmwareDfuTuning` defaults, so the tested speed setting does not drift between apps.
- The iPhone verifier can now run controlled benchmark overrides without code edits:

```sh
DFU_PRN=8 DFU_OBJECT_PREP_DELAY=0.3 ./script/verify_ios_ota.sh --wireless-only --target <new-version>
```

For a repeatable matrix, use the benchmark runner. It runs each case serially and writes one JSON report per OTA attempt plus an aggregate `summary.json`.

```sh
./script/benchmark_ios_ota_matrix.sh --target <new-version> --runs 3
```

For local iPhone hardware runs, keep the project team-neutral and pass your Apple team ID only through the environment when command-line signing needs it:

```sh
DEVELOPMENT_TEAM=<team-id> ./script/benchmark_ios_ota_matrix.sh --target <new-version> --runs 3
```

## Latest Hardware Benchmark

Batch `20260708T043013Z` ran against the real bench controller and iPhone Air with the controller off USB-C. Both attempts verified over BLE by the post-DFU `firmware_version:0.1.0` notification.

| PRN | Object delay | Result | Duration |
| --- | --- | --- | --- |
| `8` | `0.4s` | pass | `113s` |
| `8` | `0.3s` | pass | `114s` |

This does not justify promoting the `0.3s` object-delay candidate. The measured candidate was slightly slower in the one-run hardware check, and the benchmark promotion gate still requires repeated wireless-only proofs before changing production defaults.

## Next Safe Experiments

Run these only after bumping the firmware version, rebuilding the DFU zip, and confirming the controller is not on USB-C for `--wireless-only` proofs.

1. `PRN=8`, object delay `0.3s`
   - Expected benefit: saves roughly `0.1s` per 4 KB data object, about `3s` for the current payload.
   - Risk: low, still inside Nordic's documented range.
   - Promotion rule: keep only if at least three iPhone wireless-only proofs pass and median end-to-end time improves.

2. `PRN=4`, object delay `0.3s`
   - Expected benefit: probably slower, but useful as a reliability comparison in noisy RF conditions.
   - Risk: low.
   - Promotion rule: do not promote unless it is both faster and more reliable than PRN `8`.

3. Package-size reduction
   - Expected benefit: linear. Each removed kilobyte saves about `0.7s` at the latest end-to-end rate.
   - Risk: depends on code removed.
   - Promotion rule: only remove dead code or split optional features when behavior remains covered by tests.

## Paths Not Recommended Right Now

- PRN greater than `8`: contradicts Adafruit bootloader guidance for OTA memory pressure.
- PRN disabled for production: Nordic says it can improve speed, but our measured PRN `0` run was slower and the current bootloader has explicit PRN constraints.
- Bootloader replacement just for speed: possible upside exists, but it changes the recovery/security boundary. Keep USB-C as recovery and only revisit bootloader changes after the app/firmware package size and measured PRN/object-delay matrix are exhausted.
- Custom non-Nordic BLE firmware transfer: potentially much faster, but it would require a custom verified writer, rollback story, and recovery behavior. Treat it as a later engineering project, not a quick optimization.

## Recommended Implementation Path

1. Keep stable production defaults at PRN `8` and object delay `0.4s`.
2. Keep PRN `8` with object delay `0.3s` as a benchmark-only candidate unless a repeated hardware matrix beats the stable default.
3. Record every proof in `docs/ota-last-run.json` plus detailed logs under `docs/ota-telemetry/`.
4. Promote a faster default only after repeated wireless-only iPhone proofs and one Mac proof pass without USB-C recovery.
5. Continue reducing firmware size when behavior can be preserved.

## Benchmark Promotion Gate

Do not change the production defaults unless all of the following are true:

1. `script/benchmark_ios_ota_matrix.sh --target <new-version> --runs 3` completes with no failed attempts for the candidate setting.
2. The candidate median is faster than stable PRN `8`, object delay `0.4s` by at least `3s` end-to-end, or by at least `5%` if the package size has changed.
3. One Mac `firmware-proof` run passes with the same candidate app defaults after promotion.
4. The controller still verifies the firmware version over BLE after DFU, not USB-C.
5. USB-C recovery remains available and no pairing/settings data is lost.

## Source References

- [Nordic iOS DFU Library `DFUServiceInitiator.swift`](https://github.com/NordicSemiconductor/IOS-DFU-Library/blob/main/Library/Classes/Implementation/DFUServiceInitiator.swift): PRN and object-prep delay behavior.
- [Adafruit nRF52 Bootloader README](https://github.com/adafruit/Adafruit_nRF52_Bootloader): OTA PRN must be `8` or less.
- [Apple Technical Q&A QA1931](https://developer.apple.com/library/archive/qa/qa1931/_index.html): BLE advertising and connection parameters for stable Apple-device connections.
- [Nordic S140 SoftDevice throughput documentation](https://docs.nordicsemi.com/r/bundle/sds_s140/page/sds/s1xx/ble_data_throughput/ble_data_throughput.html): BLE throughput depends on ATT MTU, data length, connection interval, event length, and write/notification method.
