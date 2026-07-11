# Door Unlocker v0.2.1 Release Readiness

**PASS: v0.2.1 supersedes v0.2.0 as the stable software release.**

The earlier `v0.2.0` release was promoted before later startup, presentation, and multi-client stability failures were found. It remains available only as superseded history and should not be treated as the recommended build.

This decision applies to the software and current bench controller firmware. It does not certify the prototype as a commercial access-control, life-safety, electrical, fire, weather, or mechanical product.

## Candidate

| Component | Version |
| --- | --- |
| iPhone app | `0.2.1` build `3` |
| Mac app and CLI | `0.2.1` release line |
| Controller firmware | `0.1.26` |
| Commit | release tag `v0.2.1` |

## Blocking Gates

| Gate | Result |
| --- | --- |
| Canonical base quality suite | PASS, 19/19 |
| Full release campaign | PASS, 24/24 including live hardware and final installs |
| Shared package | PASS, 121 tests |
| Mac core/admin package | PASS, 19 tests |
| iOS adapter target | PASS, 8 tests |
| Firmware compile and package contract | PASS |
| Exact firmware BLE OTA proof | PASS, 86 seconds, no controller USB |
| Critical-path architecture/contracts | PASS |
| iOS and Mac generic builds | PASS |
| GitHub CI and Pages | Required on tagged commit |

## Physical Launch Gates

The collector ran on a physical iPhone with the paired XIAO nRF52840 controller. Cold launch means a terminated app process reaching the full secure `canAcceptDoorCommand` predicate. Warm launch means returning the existing background process to the foreground and measuring from scene activation to that same predicate.

| Mode | Samples | Median | p95 | Limit |
| --- | ---: | ---: | ---: | ---: |
| Cold | 10 | `307.5 ms` | `400 ms` | median `550 ms`, p95 `800 ms` |
| Warm | 10 | `0 ms` | `0 ms` | median `100 ms`, p95 `150 ms` |

Warm readiness rounds to zero because the authenticated BLE session and prepared command material remain current while the app is backgrounded; no reconnect or secure refresh is required at scene activation.

The machine-readable proof records every sample and a SHA-256 digest over the critical iOS app, shared package, firmware, project, and benchmark sources. CI fails if those sources change without a new physical run.

## Security Contract

The launch optimization does not bypass security. Door commands still require a trusted device key, authenticated current link, fresh controller nonce, signed command packet, anti-replay validation, current boot session, healthy storage, and authoritative door state. USB-C remains the physical recovery boundary, and the firmware package itself remains unsigned as documented in the project security limitations.

## Evidence

- [Physical launch proof](ios-launch-performance-last-run.json)
- [Firmware OTA proof](firmware-release-proof.json)
- [Canonical quality report](quality-suite-last-run.json)
- [Cold-launch engineering report](ios-cold-launch-performance-2026-07-11.md)

## Residual Risk

This is a tested prototype release, not a commercial lock certification. Bluetooth timing can vary with RF conditions, iOS scheduling, distance, and concurrent centrals. The 10-sample gates establish the release baseline and prevent silent regression; they do not guarantee identical timing in every environment.
