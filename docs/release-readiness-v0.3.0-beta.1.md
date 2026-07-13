# Door Unlocker v0.3.0 Beta 1 Readiness

**PRERELEASE BETA. NOT YET A PRODUCTION HARDWARE RELEASE.**

This release identifies the shared iPhone/Mac command path, signed wireless update flow, multi-client synchronization, and firmware-update progress reporting. The custom transactional activation path has been removed in favor of the upstream Nordic dual-bank/settings implementation. Exact-build signed USB recovery now passes. It remains a beta because the current bootloader artifact has not completed every physical power-loss, updater-interruption, Bluetooth-loss, and unsigned-package case required by the production firmware gate.

## Versions

| Component | Version |
| --- | --- |
| iPhone app, widget, and controls | `0.3.0` build `4` |
| Mac app and CLI | `0.3.0` build `4` |
| Controller firmware | `0.1.32` current development build |
| Release tag | `v0.3.0-beta.1` |

## Included

- Shared secure `v3` command model for iPhone and Mac, with P-256 signatures, counters, and connection-private nonces.
- Up to four trusted and four simultaneous BLE clients, with per-subscriber state and roster delivery.
- Wireless-first signed application and bootloader updates from trusted iPhone and Mac clients.
- Update owner, progress, and ETA presentation across connected clients.
- Durable update journals and bounded recovery after app termination or transient Bluetooth loss.
- Current low-latency lock/unlock path, shared parser/policy modules, and modularity/parity gates.

## Validation Standard

The latest `python3 script/quality_suite.py --fast` campaign passed 12 of 14 gates. Firmware/bootloader contracts and shared/Mac tests pass. The open gates are the maintainability score (`84.8/100` against a `90` target) and the content-bound physical iPhone launch proof, because release identity and critical sources changed after the prior benchmark. Machine-readable results are stored beside this report.

This gap is acceptable for a GitHub prerelease, but not for promotion to a non-beta stable release. Reinstall the exact build on the physical iPhone, run `python3 script/benchmark_ios_launch_gates.py --samples 10`, then rerun the full suite before stable promotion.

The exact signed Mac OTA release-proof run passed BLE entry, upload, reboot, immediate verification, and a fresh controller snapshot after 15 seconds. Its `111s` upload (roughly `1.2 KB/s`) is slower than the historical roughly `6 KB/s` Mac baseline, so Mac OTA throughput remains a beta performance issue. iPhone OTA remains the preferred routine path while this is investigated.

The stricter `python3 script/quality_suite.py --firmware-release` gate is intentionally separate. It requires content-bound proof that the exact current bootloader artifact is installed, completed two consecutive OTA transitions, mounted its read-only USB recovery volume, recovered through signed serial DFU, and passed the full rollback, interruption, preservation, and unsigned-rejection campaign. Until that passes, the bootloader must not be described as production-proven.

## Safety Boundary

This is a tested desk prototype, not a certified lock, access-control product, electrical product, fire/weather enclosure, or life-safety device. The release tag describes software maturity only.
