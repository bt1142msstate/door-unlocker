# iPhone Cold-Launch Connection Performance

Measured on Brandon's iPhone Air with the paired XIAO nRF52840 controller on July 11, 2026.

## Result

| Path | Firmware | Command-ready time |
| --- | --- | ---: |
| Previous forced clean reconnect | `0.1.24` | 4,905 ms |
| Restored-link reuse, 5-run range | `0.1.24` | 760-1,154 ms |
| Compact critical snapshot, 10-run range | `0.1.25` | 426-613 ms |

The final 10-run median was `500 ms` and nearest-rank p95 was `613 ms`. This is an `89.8%` reduction from the measured 4,905 ms baseline and a `41.5%` reduction from the prior 855 ms restored-link median. Every final launch stayed below the `800 ms` physical-device gate.

## What Changed

- A connected CoreBluetooth restoration is reused immediately, including cached GATT discovery.
- The app still requires a fresh controller boot session, healthy storage, an authenticated link, a current door-state snapshot, and fresh signed command material before dispatch.
- Firmware `0.1.25` can return boot session, storage health, and door state in one compact notification while link authentication and command-payload preparation run in parallel.
- The compact snapshot is retried until all three critical facts are current. A partial notification cannot mark startup complete or strand the app between states.
- A restored connection that does not provide a fresh boot-session marker within two seconds is discarded and recovered through a clean reconnect.
- Startup telemetry now reports `door_command_dispatch_ready` only when the complete secure command contract can dispatch immediately. Receiving a nonce alone no longer counts as ready.

## Evidence

- Final paced physical cold launches: `579`, `553`, `456`, `440`, `523`, `477`, `426`, `437`, `613`, and `525 ms`.
- An additional detailed trace reached true command readiness in `422 ms`.
- A final three-cycle command-bearing relaunch test reached iPhone readiness in `270-398 ms`; alternating iPhone/Mac lock commands were physically confirmed in `70-85 ms`.
- The shared startup policy, parser, firmware capability policy, and existing freshness tracker are covered by the 121-test shared package suite.
- The exact `0.1.25` package was installed and post-reboot verified over BLE in `85s` with no controller USB connection.
- `script/benchmark_ios_startup.sh` now fails when true command readiness is missing or exceeds `800 ms`.

The broader mixed-client relaunch campaign remains a separate gate because it also requires connection-roster propagation between the iPhone and Mac. That cross-client concern is not used to inflate or hide the iPhone cold-launch result.

## Release Gates

The later `v0.2.1` release run formalized this work as a content-bound physical gate. On final firmware `0.1.26`, the fully settled harness measured ten cold launches at `233-400 ms`, with a `307.5 ms` median and `400 ms` p95. Ten warm background-to-foreground activations were already secure-command-ready in the scene activation callback and therefore rounded to `0 ms`.

`script/check_ios_launch_performance_proof.py` runs in both the local quality suite and GitHub CI. It rejects missing or insufficient samples, recomputed metric mismatches, threshold failures, app/firmware version drift, and any change to the critical iOS/shared/firmware source hash after measurement.

After the user-facing Mac bundle was consolidated from `DoorUnlockerAdmin.app` to `Door Unlocker.app`, the content-bound proof was recollected because the physical mixed-client harness path changed. The refreshed ten cold launches measured `259-315 ms`, with a `277.5 ms` median and `315 ms` p95; ten warm activations remained `0 ms` at the telemetry resolution. The immutable `v0.2.1` release figures above remain the measurements captured for that tag.
