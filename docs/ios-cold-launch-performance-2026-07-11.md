# iPhone Cold-Launch Connection Performance

Measured on Brandon's iPhone Air with the paired XIAO nRF52840 controller and firmware `0.1.24` on July 11, 2026.

## Result

| Path | Command-ready time |
| --- | ---: |
| Previous forced clean reconnect | 4,905 ms |
| Optimized restored-link reuse, 5-run range | 760-1,154 ms |

The five-run median was `855 ms`. This is an `82.6%` reduction from the measured baseline median-equivalent sample, and every measured launch stayed below the `2,000 ms` physical-device gate.

## What Changed

- A connected CoreBluetooth restoration is reused immediately, including cached GATT discovery.
- The app still requires a fresh controller boot session, healthy storage, an authenticated link, a current door-state snapshot, and fresh signed command material before dispatch.
- A restored connection that does not provide a fresh boot-session marker within two seconds is discarded and recovered through a clean reconnect.
- Startup telemetry now reports `door_command_dispatch_ready` only when the complete secure command contract can dispatch immediately. Receiving a nonce alone no longer counts as ready.

## Evidence

- Five paced physical cold launches: `760`, `898`, `855`, `1,154`, and `797 ms`.
- An additional command-bearing relaunch reached command-ready in `749 ms` and confirmed unlock in `156 ms`.
- The restoration policy has four independent unit tests covering reuse, connecting/disconnected behavior, timeout recovery, and successful validation.
- `script/benchmark_ios_startup.sh` now fails when true command readiness is missing or exceeds `2,000 ms`.

The broader mixed-client relaunch campaign remains a separate gate because it also requires connection-roster propagation between the iPhone and Mac. That cross-client concern is not used to inflate or hide the iPhone cold-launch result.
