# OTA Completion Audit

Last updated: 2026-07-13

This matrix separates source/model evidence from evidence collected on the exact installed bootloader. A bootloader rebuild changes the artifact hash and invalidates exact-device claims until that artifact is installed and the physical campaign is rerun.

## Current Candidate

- Board: `xiao_nrf52840_ble_sense`
- Bootloader: Adafruit nRF52 Bootloader `0.11.0`, S140 `7.3.0`
- Signed application updates: required, P-256 ECDSA
- Dual-bank staging: enabled
- Activation: upstream dual-bank/settings implementation; no parallel custom journal
- Application isolation: nRF52840 ACL blocks application writes to the MBR and bootloader/settings range
- Physical recovery: double-reset read-only `XIAO-SENSE` volume plus signed USB CDC serial DFU
- Maximum application: `397,312` bytes
- Current signed application: `134,612` bytes
- Candidate bootloader SHA-256: read from `docs/firmware-signing-public-key.json`
- Candidate USB recovery build ID: `b2409e808fefca642042`
- Installed proof SHA-256: read from `docs/ota-bootloader-installed-proof.json`

The candidate and installed hashes must be identical before any physical evidence is accepted by the production gate.

The July 13 `0.1.30` beta upload exposed a post-DFU activation defect: validation and transfer reached 100%, but the custom activation callback did not commit the new boot target. The controller was recovered wirelessly by restoring the upstream dual-bank bootloader; the same package then activated as `0.1.30`. See `docs/ota-activation-incident-2026-07-13.md`.

## Requirement Matrix

| Requirement | Candidate/model evidence | Exact installed-hardware evidence | Status |
| --- | --- | --- | --- |
| Signed firmware enforcement | Package signature and public-key contract pass; normal ZIP/UF2 releases are application-only and the recovery volume is read-only | Earlier signed bootloader rejected the unsigned package | Pending exact-candidate rerun |
| Fast BLE transport | MTU 247, 244-byte payload, DLE, automatic PHY, fixed 15 ms interval, connection-event extension | Trusted-iPhone runs measured `15,149`, `16,300`, and `17,170 B/s` on the release profile | Pass for beta; pending exact-candidate production rerun |
| Transfer power loss | Dual-bank model preserves bank 0 at all 100 transfer cut points | Earlier signed bootloader passed battery cuts at 30% and 80% upload | Pending exact-candidate rerun |
| Activation power loss | Invalid-app startup defaults to BLE DFU so an interrupted activation can be retransmitted without USB-C | Exact candidate still requires interruption testing | Pending exact-candidate proof |
| App termination/relaunch | Durable shared update journal and bounded restart path are covered by contracts | Earlier signed bootloader passed 30% and 80% iPhone termination | Pending exact-candidate rerun |
| Bluetooth loss | Bounded transport retry and normal-mode-first reconciliation are covered by contracts | Earlier signed bootloader passed a 40% forced loss | Pending exact-candidate rerun |
| Partial/corrupt package | Signed package hash/signature checks and corrupt-image simulator cases pass | Earlier signed bootloader rejected the unsigned package | Pending exact-candidate rerun |
| Verification/reboot failure | Promotion requires the expected post-reboot BLE firmware version; 100% transport progress is insufficient | `0.1.30 -> 0.1.31 -> 0.1.32` passed on the corrected bootloader | Pass for activation; fresh promotion evidence still required |
| Physical USB recovery | Build requires the read-only `XIAO-SENSE` volume and signed CDC recovery while app packages are application-only | Exact build `b2409e808fefca642042` mounted read-only, rejected a write, and completed signed serial recovery to `0.1.32` | Pass |
| Pairing/config preservation | Bootloader preserves the reserved application-data region | Exact-build USB recovery preserved two pairings, `College View Door`, the 15-second timeout, and `95`/`20` angles | Pass |
| iPhone wireless update | Shared DFU tests and iOS adapter contracts pass | Earlier signed bootloader passed wireless entry, upload, reboot, and BLE version verification | Pending exact-candidate rerun |
| Mac wireless update | Shared DFU and Mac independent tests pass | Earlier signed bootloader passed wireless entry, upload, reboot, and BLE version verification | Pending exact-candidate rerun |
| Regression gates | Contract tests, upstream dual-bank simulator, maintainability, modularity, parity, and fast suite pass | Production gate intentionally rejects the current hash mismatch | Pass, with physical gate open |

## Release Rule

Do not promote the candidate to production until all of the following are true:

1. The migration artifact is installed and `docs/ota-bootloader-installed-proof.json` records the exact candidate hash.
2. A clean signed iPhone OTA and a clean signed Mac OTA verify the expected firmware version over BLE.
3. Unsigned or corrupt input is rejected while a valid application remains recoverable.
4. Upload interruption, activation interruption, app termination, and Bluetooth-loss cases pass on the exact candidate.
5. Trusted devices, lock name, timeout, and servo angles survive the campaign.
6. `python3 script/quality_suite.py --firmware-release` passes without overrides.
7. `python3 script/verify_usb_recovery.py --capture-baseline` is followed by a physical double reset and `python3 script/verify_usb_recovery.py --exercise --write-proof` on the exact candidate.

Until then, the candidate is a validated engineering build, not a production-proven bootloader.

Two early bootloader-only BLE attempts were rejected before image bytes were written because the package used the wrong XIAO hardware revision. Correcting the package revision to `52840` allowed signed bootloader-only replacement over BLE. This proves the wireless migration path, but it does not replace the content-bound production campaign required above.
