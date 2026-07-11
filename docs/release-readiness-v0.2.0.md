# Door Unlocker v0.2.0 Release Readiness

## Outcome

**PASS: v0.2.0 is accepted as the first software-stable Door Unlocker release.**

The final candidate passed all 23 release gates on July 11, 2026, including independent tests, architecture and contract checks, both application builds, physical iPhone/Mac multi-client operation, repeated application relaunches, cross-client settings changes, final installation, and a physical BLE firmware update with no controller USB connection.

This decision applies to the software and current bench controller firmware. It does not certify the prototype as a commercial access-control, life-safety, electrical, fire, weather, or mechanical product.

## Tested Artifacts

| Artifact | Version or evidence |
| --- | --- |
| iPhone app | `0.2.0` |
| Mac app and CLI | `0.2.0` release line |
| Controller firmware | `0.1.24` |
| Firmware application size | `134,148` bytes flash, `26,100` bytes RAM |
| DFU payload SHA-256 | `6178320154e6b6e7500b83735febbc87677c3be563bbeced02587ddf7268c5c3` |
| Machine-readable suite result | [quality-suite-last-run.json](quality-suite-last-run.json) |
| Physical OTA proof | [firmware-release-proof.json](firmware-release-proof.json) |

The payload hash is calculated from the files inside the DFU archive, so archive timestamps cannot invalidate or falsely satisfy the proof.

## Release Gates

| Gate | Result | Evidence |
| --- | --- | --- |
| Full release suite | PASS | 23 of 23 steps |
| Quality-tool negative controls | PASS | 17 tests |
| Shared package tests | PASS | 101 tests |
| Mac core/admin tests | PASS | 19 tests |
| iOS adapter tests | PASS | 5 tests |
| Maintainability | PASS | `92.4/100`, required `90` |
| iOS modularity | PASS | `96.7/100`, required `95` |
| Mac modularity | PASS | `98.4/100`, required `95` |
| Shared iOS/Mac parity registration | PASS | `100/100` |
| Exhaustive session assessment | PASS | 21,504 combinations |
| Randomized freshness tracking | PASS | 250,000 events |
| Randomized adverse interleavings | PASS | 500,000 events |
| Per-subscriber FIFO delivery | PASS | 250,000 events |
| Subscription/startup delivery race | PASS | 250,000 events |
| Live relaunch campaign | PASS | 10 cycles |
| Live alternating iPhone/Mac commands | PASS | 20 commands, 20 cross-subscriber confirmations |
| Live cross-client settings | PASS | 4 changes, 4 cross-subscriber confirmations |
| Physical BLE OTA | PASS | Signed BLE entry, no controller USB, post-reboot BLE verification in 78 seconds |
| Final Mac and iPhone installation | PASS | Both tested artifacts installed |

The final 20-command campaign confirmed commands in `34-150 ms`, with a `57.5 ms` median and `91 ms` p95. The final four durable setting changes confirmed in `2.808-3.102 s`. The 10 relaunch cycles recovered the iPhone in `2.552-2.878 s`, recovered the Mac in `2.249-2.725 s`, and confirmed every command in `36-90 ms`.

## Failure Found And Resolved

An earlier release-candidate rerun failed on relaunch cycle 10. Both clients remained connected, but the Mac missed one connection-roster notification and stopped requesting metadata after it had already received the firmware version. The following command campaign then exposed a separate test-observability race in which a detached `devicectl` console overlapped the next cold launch.

The production fix now keeps requesting snapshots until the current boot session, storage health, door state, connection roster, and firmware version are all present. That completeness rule is shared by both apps and has independent unit coverage. The harness now explicitly terminates and settles the prior iPhone process before attaching its next console. The isolated relaunch test and the complete 23-gate campaign both passed after these fixes.

## Adverse Scenarios Covered

The release campaign exercises or statically enforces these failure paths:

- stale, missing, reset, or contradictory controller session metadata;
- Bluetooth loss during discovery, authentication, command dispatch, and state synchronization;
- a weak or unavailable link followed by restoration;
- Core Bluetooth state restoration with a stale peripheral instance;
- duplicate, delayed, out-of-order, and missing state observations;
- command single-flight ownership and rapid alternating requests;
- iPhone and Mac simultaneous subscriptions without one client consuming another client's update;
- bounded per-subscriber FIFO overflow with explicit reconnect recovery;
- disconnect/reconnect generation changes so an old connection cannot receive new-session data;
- notification subscription startup races, including duplicate critical session delivery;
- controller reset, storage-health failure, invalid USB identity, and fail-closed pairing truth;
- transactional pairing persistence during interruption or unstable power;
- cross-client settings races and durable controller confirmation;
- interrupted or relaunched DFU verification, missing completion callbacks, normal-mode recovery probes, and exact-payload verification.

## Residual Risk

- The controller reports commanded actuator state; there is no physical bolt, handle, or door-position sensor.
- iOS proximity behavior remains subject to Bluetooth range, location accuracy, background execution policy, force-quit behavior, and system power management.
- OTA requires a trusted device, BLE reachability, and a working bootloader. USB-C remains the recovery path after an unrecoverable interruption.
- The current DFU application package is not independently code-signed by a hardware root of trust. OTA entry is authenticated by the trusted-device command protocol.
- The current enclosure, adhesive mount, battery system, wiring, weather resistance, and servo force have not received third-party safety or durability certification.
- The security design has automated contract coverage but has not received an independent penetration test or formal cryptographic audit.

These limits are why the repository continues to describe the hardware as a bench prototype, even though the tested software release is stable.

## Reproduction

Run the complete non-destructive local suite with:

```sh
python3 script/quality_suite.py
```

With both trusted apps, the controller, and safe bench hardware available, run the physical release campaign with:

```sh
python3 script/quality_suite.py --live-mixed-client --firmware-release --install-mac --install-ios
```

Raw live telemetry is intentionally excluded from Git because it can contain local device names and filesystem paths. The checked-in quality summary and firmware proof preserve the release decision, measurements, versions, and payload identity without those private identifiers.
