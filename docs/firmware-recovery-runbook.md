# Firmware Recovery Runbook

This runbook is the required escape path for every Door Unlocker controller
firmware release. A release is not production-ready merely because an OTA
upload reaches 100%.

## Recovery Layers

| Controller state | Expected recovery | Required proof |
| --- | --- | --- |
| OTA transfer interrupted before activation | Existing application remains in dual-bank bank 0 | Transfer interruption tests and post-reboot version check |
| New application invalid or activation incomplete | Bootloader advertises `DoorDFUStable` and accepts the signed application again | Invalid-app BLE recovery test |
| Phone/Mac updater closes or loses Bluetooth | Relaunch reconnects and resumes or restarts the signed transfer | App-termination and Bluetooth-loss tests |
| Application cannot run | Double-press reset while USB is connected; read-only `XIAO-SENSE` must mount | Exact-build physical USB proof |
| USB recovery is active | Send the signed application ZIP over the USB CDC serial port | Signed serial recovery plus settings comparison |
| Bootloader itself is damaged | Use SWD/J-Link to restore the audited bootloader | Bench/development fallback; not a customer OTA path |

This is a layered recovery design, not an absolute software guarantee. If the
MBR or bootloader flash is physically damaged or corrupted, code on the device
cannot repair itself because none of that code can run. The XIAO SWD pads plus
a J-Link-compatible probe are therefore the final deterministic recovery path.
USB-C and BLE cover application and ordinary update failures; SWD covers the
remaining bootloader/MBR failure class.

## Required Recovery Ladder

Every shipped firmware and bootloader combination must preserve all four
levels:

1. **Normal application:** trusted BLE control and signed OTA remain available.
2. **Invalid application:** the bootloader automatically advertises
   `DoorDFUStable` so a signed image can be sent again.
3. **Manual USB recovery:** a reset-button double press mounts the read-only
   `XIAO-SENSE` volume and exposes USB CDC signed DFU without relying on the app.
4. **Hardware recovery:** the enclosure and PCB service plan must keep SWD pads
   reachable for J-Link recovery if the MBR or bootloader cannot execute.

Adafruit bootloader `0.11.0` is pinned to its audited upstream commit. That
release protects the MBR and bootloader/settings range from application writes
with the nRF52840 ACL peripheral. The build fails if ACL support is absent, and
the release contract verifies that the protection code is linked.

## Normal USB Recovery Proof

1. Connect the running controller to the Mac by USB-C.
2. Capture its USB identity and persistent state:

   ```sh
   python3 script/verify_usb_recovery.py --capture-baseline
   ```

3. Double-press reset. The Mac must mount `/Volumes/XIAO-SENSE`.
4. Exercise the exact recovery build and return to the current application:

   ```sh
   python3 script/verify_usb_recovery.py --exercise --write-proof
   ```

The second command checks the board ID, the hardware-reported
`Door-Bootloader-ID`, the USB serial number, read-only media behavior, signed
serial DFU, the recovered firmware version, and preserved pair count, lock
name, timeout, and servo angles. It writes `docs/usb-recovery-proof.json` only
when every check passes.

## Per-Release Invariants

Every firmware revision must pass:

```sh
python3 script/check_ota_bootloader_contract.py --require-release-invariant
```

The normal firmware build also runs:

```sh
python3 script/check_ota_bootloader_contract.py --require-firmware-artifacts
```

These gates reject application ZIPs that include a bootloader, SoftDevice, or
MBR image; reject UF2 blocks outside the application region; reject oversized
images that cannot use dual-bank staging; and require the separately signed
recovery bootloader artifact, ACL write-protection contract, and public-key
contract. GitHub CI runs the clean-checkout recovery invariant for every
change. Every `v*` tag, including betas, additionally requires the exact
installed content-bound bootloader and physical USB recovery proof plus the
exact application BLE OTA proof. A non-prerelease tag also requires two
content-bound OTA transitions and the complete power-loss,
updater-termination, Bluetooth-loss, persistence, and unsigned-package
rejection campaign.

Bootloader candidates also pin `SOURCE_DATE_EPOCH` so the upstream UF2 compile
timestamp cannot change executable bytes between builds. The recovery build ID
is derived from the upstream commit, signing-key identity, transport settings,
build script, patcher, and compiler identity. Promotion requires two clean
builds with matching code, full-image, migration-UF2, and OTA-package hashes.

## Promotion Rule

A new bootloader hash invalidates all earlier physical recovery evidence. The
exact build must report its build ID over USB and complete signed serial
recovery before any beta or stable tag can pass. Application-only releases
retain the already-proven bootloader, but still rerun the application package
and UF2 range checks so they cannot remove the escape hatch.
