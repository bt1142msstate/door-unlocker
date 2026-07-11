# Command Path Stability - 2026-07-10

## Status

Mac single-client hardware verification passes. iPhone authentication was verified
before the phone left, but the final simultaneous iPhone/Mac stress pass remains
pending until the phone is available again.

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

## Real-controller measurements

Controller firmware: `0.1.10`

Firmware `0.1.11` is the next candidate. It adds a two-job per-connection quota,
per-client overflow rejection, alternating normal/busy scheduling, and queued-job
purging on disconnect. It compiles and packages, but is not yet physically
verified.

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
remaining physical two-client run directly measurable from both clients.

## Remaining acceptance test

With the iPhone present, keep both apps connected and alternate commands and
settings from each client. Acceptance requires no disconnect loop, no stale UI
rollback, no false confirmation error, correct connected-device count, and the
same sub-100 ms controller-confirmation behavior for already-prepared commands.
