# Door Unlocker v0.3.0 Beta 1 Readiness

**PRERELEASE BETA. NOT YET A PRODUCTION HARDWARE RELEASE.**

This release identifies the current shared iPhone/Mac command path, signed wireless update flow, multi-client synchronization, and firmware-update progress reporting. It remains a beta because the exact current transactional bootloader artifact has not completed every physical power-loss and unsigned-package case required by the production firmware gate.

## Versions

| Component | Version |
| --- | --- |
| iPhone app, widget, and controls | `0.3.0` build `4` |
| Mac app and CLI | `0.3.0` build `4` |
| Controller firmware | `0.1.30` |
| Release tag | `v0.3.0-beta.1` |

## Included

- Shared secure `v3` command model for iPhone and Mac, with P-256 signatures, counters, and connection-private nonces.
- Up to four trusted and four simultaneous BLE clients, with per-subscriber state and roster delivery.
- Wireless-first signed application and bootloader updates from trusted iPhone and Mac clients.
- Update owner, progress, and ETA presentation across connected clients.
- Durable update journals and bounded recovery after app termination or transient Bluetooth loss.
- Current low-latency lock/unlock path, shared parser/policy modules, and modularity/parity gates.

## Validation Standard

The current `python3 script/quality_suite.py` campaign passed 23 of 24 gates. All shared, Mac, and iOS adapter tests; firmware/bootloader contracts; generic app builds; and wiring/CAD checks passed. The only failure is the content-bound physical iPhone launch proof: the release identity and critical sources changed after the prior benchmark, and the paired phone was unavailable for recollection. Machine-readable results are stored beside this report.

This gap is acceptable for a GitHub prerelease, but not for promotion to a non-beta stable release. Reinstall the exact build on the physical iPhone, run `python3 script/benchmark_ios_launch_gates.py --samples 10`, then rerun the full suite before stable promotion.

The stricter `python3 script/quality_suite.py --firmware-release` gate is intentionally separate. It requires content-bound proof that the exact current bootloader artifact is installed and passed the full physical rollback, interruption, preservation, and unsigned-rejection campaign. Until that passes, USB-C/SWD remain recovery fallbacks and the bootloader must not be described as production-proven.

## Safety Boundary

This is a tested desk prototype, not a certified lock, access-control product, electrical product, fire/weather enclosure, or life-safety device. The release tag describes software maturity only.
