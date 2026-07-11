# Command Path Stability - 2026-07-10

## Status

Mac single-client and alternating iPhone/Mac hardware verification pass. The final
mixed-client command and settings runs were completed July 11, 2026; their checked-in
JSON reports supersede the pending acceptance note in the original July 10 record.

## Fixes verified

- iOS and macOS state recovery use read-only snapshot requests. They never toggle
  state notifications to force a replay.
- iOS no longer replaces its signing identity when the Secure Enclave is
  temporarily unavailable while the device is locked.
- iOS and macOS share absolute command-confirmation deadlines: state reads at
  300 ms and 1.2 s, with failure at 2.5 s.
- macOS uses one reconnect owner. CoreBluetooth auto-reconnect no longer competes
  with the app backoff scheduler.
- A macOS connection attempt has a five-second deadline instead of recursively
  polling every 150 ms forever.
- macOS starts Bluetooth before serial-port discovery.
- Setting operations remain in flight for up to five seconds, but complete
  immediately when the authoritative controller notification arrives.
- iOS and macOS now defer a new local door request while the controller is in a
  transition or that client still awaits confirmation. Each client retains its
  newest semantic intent and dispatches it only after stable-state confirmation.
- Each connection has independent nonce state. Firmware consumes a valid nonce
  before executing its authenticated command; replay is rejected as `missing_nonce`
  or `bad_nonce` and gets fresh connection-private material. Both apps also ignore
  a duplicate notification of the nonce most recently consumed on that connection.
- The firmware queue limits each connection to two jobs, targets overflow rejection
  only to the responsible connection, alternates queued jobs with overflow responses,
  and removes a connection's pending jobs when it disconnects.

## Real-controller measurements

Controller firmware/app bundle under current validation: `0.1.24`.

The two-job per-connection quota, per-client overflow rejection, alternating
normal/busy scheduling, and queued-job purging that were candidates on July 10 are
now present in the current firmware path. The July 11 mixed-client runs physically
exercise the current command and settings path; they are not a synthetic claim of
every overflow or disconnect branch.

The first `0.1.11` OTA attempt exposed a cancelled-task bug in the Mac reconnect
deadline. Cancelled deadline tasks resumed during DFU and briefly produced a
reconnect storm. All transport and firmware deadline sleeps now return on
cancellation, firmware mode excludes normal reconnect work, and the structural
gate forbids cancellation-swallowing sleeps in those files. The interrupted
controller stopped advertising both normal and DFU services before recovery
could run, so physical recovery/version verification remains pending; no claim
is made that `0.1.11` is installed.

The standalone `door-unlocker` CLI also lacked a valid signature after being
copied from SwiftPM output. Packaging now signs and verifies the CLI with the
same stable local identity as the app and executes a `--help` launch smoke test.

Mac startup after the reconnect simplification:

| Milestone | Observed time |
| --- | ---: |
| Bluetooth central created | 2-4 ms |
| Physical BLE connection | 927-1,265 ms |
| GATT ready | 1,401-1,822 ms |
| Secure nonce received | 1,810-2,229 ms |
| First pre-signed unlock payload ready | 2,004-2,394 ms |

Alternating lock/unlock stress:

- Commands: 16
- Confirmed: 16
- Failed confirmations: 0
- Reconnects during the pass: 0
- Request-to-controller-notification latency: 36-92 ms
- Median latency: 61.5 ms
- Mean latency: 68.3 ms

The accessibility-driven Mac UI smoke test also clicked the actual menu control,
not the CLI bridge. Its request was written in 1 ms and confirmed by the
controller in 36 ms.

The installed Mac app then remained continuously ready for more than seven
minutes with zero disconnects, connection-deadline recoveries, or command
confirmation failures.

Rapid setting replacement:

- Ten timeout values were submitted 120 ms apart.
- The Mac app coalesced them into one `auto-lock 30s` command.
- The controller announced `setting_applying:timeout:30` after 50 ms.
- The controller published durable `timeout_set:30` after 2,986 ms.
- The operation cleared from the authoritative notification with no retry or
  failure.

## Automated evidence

- Shared tests: 70 passed, including opposite-state supersession cases.
- Mac core/admin tests: 18 passed.
- Fast quality suite: passed.
- iOS adapter vectors: passed in the full suite.
- iOS and Mac builds: passed in the full suite.
- Firmware compilation: passed in the full suite.
- Maintainability score: 99.1/100.
- Shared parity score: 100/100.

The full repository suite still reports unrelated bench-wiring HTML/CAD model
failures while that diagram is being redesigned. Those failures do not exercise
the app, shared command contract, Bluetooth path, or firmware build.

The iOS debug build now emits the same request, dispatch, confirmation,
rejection, and confirmation-failure timestamps as the Mac app. This makes the
physical two-client run directly measurable from both clients.

## July 11 acceptance results

The previously remaining iPhone/Mac acceptance pass is complete:

- [Single-client command stress](command-stress-last-run.json): 30/30 alternating
  Mac commands passed. Request-to-confirmation was 42-218 ms, median 150.5 ms,
  mean 150.4 ms, and p95 192 ms against a 500 ms limit.
- [Mixed-client command stress](mixed-client-stress-last-run.json): 20/20 alternating
  iPhone/Mac commands passed and all 20 were observed by the opposite subscriber.
  Controller confirmation was 66-430 ms, median 113.5 ms, mean 142.6 ms, and p95
  320 ms against a 750 ms limit. This chained run begins immediately after a Mac UI
  command and uses a 150 ms inter-command settle, so it includes stable-state queueing.
- [Mixed-client settings stress](mixed-client-settings-last-run.json): 4/4 alternating
  timeout changes passed, were observed by the opposite subscriber, and had no
  failures. Confirmation was 3,172-3,708 ms, median 3,475.5 ms, mean 3,457.8 ms,
  and p95 3,581 ms against a five-second limit. The final authoritative timeout
  was 30 seconds.

Together these measurements verify that opposite-client door commands converge in
controller order and that alternating settings converge to the final submitted
value without a false failure. Stable-state serialization remains per client:
commands already accepted from separate connections are ordered by the firmware
FIFO, while each app waits for its own in-flight transition to settle before
dispatching its retained follow-up intent.
