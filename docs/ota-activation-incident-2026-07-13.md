# OTA Activation Incident - July 13, 2026

## Impact

A signed application package reached 100% upload and passed DFU validation, but
the controller rebooted into the previously installed application. Repeating
the upload could not advance the controller beyond firmware `0.1.29`.

No pairing or controller settings were lost. The old application remained
valid and continued to operate, but the updater reported a misleading transfer
success before post-reboot activation had been proven.

## Evidence

The Mac updater telemetry established the sequence:

1. The custom bootloader was installed: the next DFU scan advertised
   `DoorDFU2` instead of `DoorDFU1`.
2. The `0.1.30` application package uploaded to `DoorDFU2`, validated, and
   reached 100%.
3. After reboot, the controller reported `firmware_version:0.1.29` over BLE.
4. The bootloader was rolled back wirelessly to the upstream dual-bank build.
5. The next DFU scan advertised `DoorDFU`, proving the rollback was active.
6. The same signed application package then completed and the rebooted
   controller reported `firmware_version:0.1.30` over BLE.

This isolates the defect to the custom activation implementation, not the
signed package, transport, application image, or BLE reconnection verifier.

## Root Cause

The custom `door_activation_stage` callback attempted to disable the Nordic
SoftDevice immediately after the BLE transport requested disconnection. BLE
disconnection is asynchronous. The flash-control transition could therefore
fail before the activation journal was committed. The transport had already
validated and received all bytes, so the client displayed 100%, but the valid
old application remained the only committed boot target.

An earlier variant also returned success after requesting `dfu_reset()` without
proving that a reset had occurred. Both variants created a second activation
state machine beside the bootloader's own persistent settings state.

## Permanent Correction

- Application activation uses the upstream Adafruit/Nordic dual-bank flow and
  its bootloader settings page. Door Unlocker no longer replaces
  `dfu_activate_app`.
- The custom activation journal source and its dedicated flash-page contract
  were removed from the build.
- Application-side background staging-bank erasure was removed. Bank ownership
  stays inside the bootloader.
- Signed updates, forced dual-bank sizing, invalid-app BLE recovery, and the
  optimized BLE transport remain enabled.
- A source gate rejects `door_activation_stage`,
  `door_activation_journal`, `ACTIVATION_JOURNAL_ADDRESS`, or
  `StagingBankMaintenance` in a release candidate.
- Every normal application package is required to contain only `application`
  and `dfu_version`; MBR, SoftDevice, and bootloader payloads fail the gate.
- The completion watchdog cannot announce upload completion or replace the
  active DFU transport until the final multipart transport part has reached
  100%. A separate progress-resetting stall timer handles transfers that stop.
- The signed bootloader builds USB mass storage into every candidate. It mounts
  `XIAO-SENSE` read-only and exposes USB CDC for signed serial DFU. This fixes a
  separate recovery gap where a signed build could enter USB bootloader mode
  without mounting a volume because mass storage had been compiled out.
- `INFO_UF2.TXT` reports a deterministic Door Unlocker recovery build ID. The
  physical proof must observe that ID and the controller's USB serial number;
  copying expected hashes from a build manifest is not accepted as evidence.
- A follow-up audit found that upstream UF2 filesystem metadata incorporated
  compile time into one executable byte. The build now pins
  `SOURCE_DATE_EPOCH`, binds the build script, patcher, and compiler identity
  into the recovery build ID, and requires two isolated builds to produce
  byte-identical HEX, migration UF2, code, and signed OTA ZIP artifacts.
- Every normal firmware ZIP and UF2 is checked to contain application addresses
  only, preserving the already-installed recovery bootloader across releases.

## Promotion Gate

A firmware build is not promoted from beta based on upload progress. It must:

1. Validate the package hash and P-256 signature.
2. Observe the expected bootloader identity after entering DFU.
3. Complete the upload and validation stages.
4. Reconnect to the normal controller service after reboot.
5. Receive `firmware_version:<expected>` from the controller over BLE.
6. Repeat the process for a second, newly built firmware version.
7. Recheck the final version after the normal application has run for at least
   15 seconds.
8. Capture the normal controller identity/settings, mount the exact bootloader
   over USB with a reset-button double press, reject a volume write, complete
   signed serial recovery, and prove the identity/settings remained intact.

If activation is interrupted after bank 0 becomes invalid, the bootloader is
configured to advertise BLE DFU automatically. The app must resume/restart the
signed transfer without requiring USB-C. This is recoverability, not a claim
that the old application always rolls back during every activation cut.

## References

- Nordic dual-bank updates retain the existing application until a new image
  is validated: https://docs.nordicsemi.com/r/bundle/nrf5_sdk_v15.0.0/page/lib_bootloader_dfu_banks.html
- Nordic bootloader settings persist current, pending, and activation state:
  https://docs.nordicsemi.com/r/bundle/nrf5_sdk_v15.2.0/page/lib_bootloader.html
- Nordic's DFU process uses the settings page to choose activation or DFU after
  reset: https://docs.nordicsemi.com/r/bundle/nrf5_sdk_v14.1.0/page/lib_bootloader_dfu_process.html
