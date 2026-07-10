# Fast lock/unlock command path

This document is the source of truth for the direct lock/unlock path shared by the iPhone app, Mac app, and XIAO firmware. Settings, pairing administration, and firmware updates use the same signed v3 packet format but intentionally use acknowledged writes because they are not latency-critical.

## Direct path

1. The controller gives each connected trusted device its own random one-time nonce.
2. Each app signs both possible door packets ahead of time with its device-local P-256 private key.
   Prepared packets remain valid for the current BLE connection instead of expiring on an app timer. The controller owns nonce validity, and both apps discard all connection-bound material on use, rejection, disconnect, or reconnect. This keeps an idle next tap on the direct path without weakening replay protection.
3. A tap or click selects the already-signed `LOCK` or `UNLOCK` packet. No signing, state read, or extra request is on the tap hot path.
4. `DoorFastWritePolicy` verifies that write-without-response is supported, the packet fits the negotiated MTU, and Core Bluetooth can currently accept another write.
5. The app submits one write-without-response and consumes the nonce only after that submission.
6. Bluefruit copies the packet into the controller's fixed command FIFO. Queue indexes and overflow state are protected by a FreeRTOS critical section because Bluefruit callbacks and the Arduino loop run on different tasks.
7. The Arduino loop validates the per-connection nonce, paired-key fingerprint, and P-256 signature.
8. The controller broadcasts `locking` or `unlocking` before writing the servo angle, so every subscribed app receives the semantic acknowledgement and the servo begins moving immediately after verification.
9. The controller broadcasts the final state to every connection and gives the issuing connection a fresh nonce.

The control characteristic is reserved for connection-private nonce and secure-command rejection traffic. It is notify/indicate-only: it has no readable shared value, and the controller targets each control payload to exactly one connection. Connected-device snapshots and door state use the shared state characteristic, so another device cannot read, overwrite, or consume the nonce needed for the next tap.

The control surface accepts one semantic command at a time. It becomes available again as soon as the matching `locking`, `unlocking`, `locked`, or `unlocked` broadcast arrives. There is no fixed UI delay; this prevents conflicting repeated taps while preserving the shortest controller-confirmed path.

Nominal tap-to-servo-command latency is one BLE connection interval plus controller dispatch and signature verification. The controller advertises an Apple-compliant 30-45 ms preferred interval, a 6-second supervision timeout, and a 3.75 ms event reservation per link. This leaves scheduling margin for four simultaneous links while keeping command latency below a perceptible UI delay. The controller loop adds at most about 2 ms of idle wait. The 180 ms servo settle period happens after the servo command and is not part of tap-to-movement latency.

The firmware does not force an exact interval after connecting. Bluefruit's exact-interval update API would produce equal minimum and maximum values, while Apple's ordinary-accessory guidance requires a 15 ms spread except for the special 15/15 ms case. The central remains free to choose a valid value from the preferred range. See [Apple QA1931](https://developer.apple.com/library/archive/qa/qa1931/_index.html).

## Backpressure and recovery

Apple documents that a write-without-response has no failure callback and should only be submitted while `canSendWriteWithoutResponse` is true. If it is false:

- The app keeps the signed packet and its nonce intact.
- One semantic command intent is queued; repeated taps remain disabled until it is resolved.
- `peripheralIsReady(toSendWriteWithoutResponse:)` sends the retained packet as soon as Core Bluetooth has capacity.
- A one-second safety watchdog reconnects only if the capacity callback never arrives. Reconnection discards connection-bound signed material, preserves the semantic lock/unlock intent, obtains a new nonce, and signs again.

This recovery path is exceptional. It does not add a timer or round trip to normal taps.

## Unified command dispatch

The Mac command transport reports exactly one outcome to every caller:

- `sent`: the Bluetooth write was submitted. The caller may begin acknowledgement handling.
- `queued`: the semantic command is retained while the connection, nonce, or transport capacity becomes ready.
- `failed`: the command was not accepted and is not waiting for transport recovery.

Firmware update, settings, pairing administration, and lock/unlock all use this contract. A queued operation can therefore never be mistaken for an already-submitted write. Non-door operations use acknowledged writes; only the pre-signed lock/unlock hot path uses write-without-response.

## Multiple devices

- The controller supports four simultaneous BLE connections and maintains a separate nonce for each connection.
- All accepted state changes are broadcast to all subscribed devices.
- Private nonce and reject events are targeted only to their owning connection.
- The trusted-device roster is rebroadcast only when membership or a displayed name actually changes, not after every authenticated command.
- A state update clears a queued or in-flight command only when it moves toward that command's target. An iPhone `unlocking` notification cannot cancel a queued Mac lock, for example.
- Commands from different devices are serialized by the controller FIFO. Opposite commands retain arrival order; redundant commands are idempotent.

## Confirmation behavior

- iOS presents its immediate transition, then treats matching controller state as the authoritative result. Timed reads recover a missed notification.
- macOS presents the same immediate `locking` or `unlocking` transition as iOS after Core Bluetooth accepts the write. It performs state reads at 250 ms, 500 ms, and 1 second if confirmation is missing, then releases the control with an error rather than spinning forever.
- Neither app treats the BLE write itself as proof that the physical state changed. The controller broadcast is the semantic acknowledgement.
- An unrelated state broadcast from another connected device cannot complete or cancel an opposite command.

On macOS 14 and newer, Core Bluetooth system auto-reconnect owns an unexpected link drop. The app preserves a queued semantic command, discards connection-bound nonce material, and resumes discovery after the same peripheral reconnects. USB-C and intentional disconnect paths explicitly cancel that behavior.

## Security invariants

- Private P-256 keys remain in each device's Keychain and are never sent to the controller or repository.
- Every packet includes a controller-issued one-time nonce and a signature over the protocol domain, command, key fingerprint, nonce, and payload.
- A nonce is invalidated after one accepted command, preventing captured packets from being replayed.
- Transport recovery never reuses a packet across BLE connections.

## Verification

Run the focused invariant check:

```sh
python3 script/check_fast_command_contract.py
```

Run the complete architecture, test, and build suite:

```sh
python3 script/quality_suite.py
```

Hardware timing should measure both tap-to-`wireless_command_sent` and tap-to-servo movement. Live lock/unlock tests are opt-in because they move the real mechanism.

## Latest hardware validation

Validated July 10, 2026 with XIAO firmware `0.1.6`:

- Firmware compile: 129,544 bytes flash (15%) and 20,040 bytes RAM (8%).
- Wireless DFU: 219.4 seconds total, verified as `0.1.6` over BLE without USB-C.
- Control stress test: six alternating Mac UI commands, all six controller-confirmed in order.
- Recovery telemetry during those six commands: zero nonce retries, reconnects, rejections, or confirmation failures.
- Settings smoke test: the current 15-second auto-lock value completed through the same queued/sent/failed dispatch contract and returned to ready.
