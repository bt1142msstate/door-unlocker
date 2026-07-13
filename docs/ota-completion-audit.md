# OTA Completion Audit

Last updated: 2026-07-13

This matrix separates source/model evidence from evidence collected on the exact installed bootloader. A bootloader rebuild changes the artifact hash and invalidates exact-device claims until that artifact is installed and the physical campaign is rerun.

## Current Candidate

- Board: `xiao_nrf52840_ble_sense`
- Bootloader: Adafruit nRF52 Bootloader `0.11.0`, S140 `7.3.0`
- Signed application updates: required, P-256 ECDSA
- Dual-bank staging: enabled
- Transactional activation journal: enabled at `0x000E9000`
- Maximum application: `397,312` bytes
- Current signed application: `134,452` bytes
- Candidate bootloader SHA-256: read from `docs/firmware-signing-public-key.json`
- Installed proof SHA-256: read from `docs/ota-bootloader-installed-proof.json`

The candidate and installed hashes must be identical before any physical evidence is accepted by the production gate.

## Requirement Matrix

| Requirement | Candidate/model evidence | Exact installed-hardware evidence | Status |
| --- | --- | --- | --- |
| Signed firmware enforcement | Package signature and public-key contract pass; unsigned UF2 is disabled | Earlier signed bootloader rejected the unsigned package | Pending exact-candidate rerun |
| Fast BLE transport | MTU 247, 244-byte payload, DLE, automatic PHY, fixed 15 ms interval, connection-event extension | Trusted-iPhone runs measured `15,149`, `16,300`, and `17,170 B/s` on the release profile | Pass for beta; pending exact-candidate production rerun |
| Transfer power loss | Dual-bank model preserves bank 0 at all 100 transfer cut points | Earlier signed bootloader passed battery cuts at 30% and 80% upload | Pending exact-candidate rerun |
| Activation power loss | Transactional journal passes 33,680 modeled activation cut points, including erase, copy, settings, commit, and reboot boundaries | Not yet run on the transactional candidate | Pending physical proof |
| App termination/relaunch | Durable shared update journal and bounded restart path are covered by contracts | Earlier signed bootloader passed 30% and 80% iPhone termination | Pending exact-candidate rerun |
| Bluetooth loss | Bounded transport retry and normal-mode-first reconciliation are covered by contracts | Earlier signed bootloader passed a 40% forced loss | Pending exact-candidate rerun |
| Partial/corrupt package | Signed package hash/signature checks and corrupt-image simulator cases pass | Earlier signed bootloader rejected the unsigned package | Pending exact-candidate rerun |
| Verification/reboot failure | Journal remains committed until bank 0 CRC and bootloader settings are valid | Not yet interrupted physically on the transactional candidate | Pending physical proof |
| Pairing/config preservation | Journal page lies outside the reserved application-data region | Earlier campaign preserved two trusted devices and controller settings | Pending exact-candidate confirmation |
| iPhone wireless update | Shared DFU tests and iOS adapter contracts pass | Earlier signed bootloader passed wireless entry, upload, reboot, and BLE version verification | Pending exact-candidate rerun |
| Mac wireless update | Shared DFU and Mac independent tests pass | Earlier signed bootloader passed wireless entry, upload, reboot, and BLE version verification | Pending exact-candidate rerun |
| Regression gates | Contract tests, transactional simulator, maintainability, modularity, parity, and fast suite pass | Production gate intentionally rejects the current hash mismatch | Pass, with physical gate open |

## Release Rule

Do not promote the transactional candidate to production until all of the following are true:

1. The migration artifact is installed and `docs/ota-bootloader-installed-proof.json` records the exact candidate hash.
2. A clean signed iPhone OTA and a clean signed Mac OTA verify the expected firmware version over BLE.
3. Unsigned or corrupt input is rejected while a valid application remains recoverable.
4. Upload interruption, activation interruption, app termination, and Bluetooth-loss cases pass on the exact candidate.
5. Trusted devices, lock name, timeout, and servo angles survive the campaign.
6. `python3 script/quality_suite.py --firmware-release` passes without overrides.

Until then, the candidate is a validated engineering build, not a production-proven bootloader.

Two early bootloader-only BLE attempts were rejected before image bytes were written because the package used the wrong XIAO hardware revision. Correcting the package revision to `52840` allowed signed bootloader-only replacement over BLE. This proves the wireless migration path, but it does not replace the content-bound production campaign required above.
