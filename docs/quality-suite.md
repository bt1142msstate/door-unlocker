# Quality Suite

`script/quality_suite.py` is the project-level gate for release changes. It combines self-tested quality tooling, architecture heuristics, executable tests, coverage evidence, firmware compilation, app builds, and wiring/CAD consistency checks.

The suite also runs the dual-bank power-loss model against the exact bundled firmware size. It tests every whole transfer percentage before activation and fails if the image no longer fits the staging bank, single-bank fallback is enabled, or a simulated cut would not select the previous firmware. Final activation-copy recovery still requires an attended physical proof on the installed candidate.

## Default Suite

Run:

```sh
python3 script/quality_suite.py
```

The default suite runs:

- quality-tool self-tests with deliberate negative controls;
- maintainability size/length gate: `script/score_maintainability.py --threshold 90`;
- low coupling, high modularity, and independence gate: `script/score_modularity.py --threshold 95`;
- iOS/Mac shared ownership and test-registration gate: `script/score_shared_parity.py --threshold 95`;
- a XIAO firmware compile plus semantic app/DFU payload contract check;
- the fast command, transactional persistence, and per-subscriber notification-delivery contracts;
- shared package tests: `swift test --package-path shared/DoorUnlockerShared`;
- Mac core/admin package tests, including parser and secure-packet adapter vectors;
- iOS host-app adapter tests on an automatically discovered simulator, with `.xcresult` coverage evidence;
- iOS generic build with signing disabled;
- Mac app build/verify;
- native SwiftUI physical-handoff assistant build;
- bench wiring, breadboard, inline splitter, and Phase 2 dimensional model checks.

It writes a machine-readable report to `docs/quality-suite-last-run.json`, iOS coverage evidence to `docs/ios-test-coverage-last-run.json`, and the raw iOS result bundle to `build/quality/ios-tests.xcresult`. Every run also validates `docs/ios-launch-performance-last-run.json` against the exact current iOS/shared/firmware critical-path hash.

The physical launch proof is collected on a real iPhone with:

```bash
python3 script/benchmark_ios_launch_gates.py --samples 10
```

The cold gate terminates the app before each sample and measures launch to authenticated command readiness. The warm gate backgrounds the still-running app and measures scene reactivation to the same readiness predicate. Current release limits are cold median `550 ms`, cold p95 `800 ms`, warm median `100 ms`, and warm p95 `150 ms`. Any critical launch-path source change invalidates the checked-in proof until the physical benchmark is rerun.

By default, independent steps continue after a failure so the report shows the complete failure set. Use `--fail-fast` only for a shorter local diagnosis loop.

## Fast Suite

Run:

```sh
python3 script/quality_suite.py --fast
```

This keeps the tooling self-tests, score gates, structural fast-path contract, and independent shared/Mac package tests. It deliberately skips iOS adapter execution, firmware compilation, app builds, and HTML/CAD checks. A passing fast run sets `passed`, but never `fullSuitePassed`.

## Optional Live Checks

These are opt-in because they can touch real devices or send real lock/unlock commands:

```sh
python3 script/quality_suite.py --live-mac-ui
python3 script/quality_suite.py --live-mixed-client
python3 script/quality_suite.py --firmware-release
python3 script/quality_suite.py --install-mac
python3 script/quality_suite.py --install-ios
```

`--live-mac-ui` opens the installed Mac app and clicks the main lock/unlock control surface through Accessibility. It is useful for catching UI action-path glitches, but it should only be used when sending a real command is safe.

`--live-mixed-client` runs repeated iPhone/Mac relaunch recovery, alternating cross-client lock/unlock commands, and durable setting changes. It requires both trusted apps and the controller to be available, and it writes private raw telemetry to ignored local report files.

`--firmware-release` requires a checked-in physical proof whose firmware version and payload hash match the exact current DFU package. It also requires the exact installed signed bootloader hash, unsigned-package rejection, app-termination and Bluetooth-loss recovery, Mac wireless verification, preserved controller state, and the complete physical power-loss campaign. Upload cuts at 30% and 80% are proven; deterministic erase and post-validation cuts remain the final production-only gate.

## What The Suite Measures

- Low coupling: view-layer dependency width, shared protocol ownership, shared policy ownership, and layer isolation.
- High modularity: feature folders, small composition roots, type/file naming, module boundaries, and view-helper sprawl.
- Shared parity registration: cross-platform ownership and registered tests for command identity, signed packets, fast/reliable writes, recovery, controller rules, state parsing, control-surface presentation, name normalization, and the complete DFU transport.
- Executable adapter parity: the same parser inputs and secure command packet expectations run against both iOS and Mac adapters.
- Independence: shared package tests, Mac core tests, CLI/core boundaries, parser/codecs/policy tests, and app builds that do not depend on a live controller.
- Size and length: SwiftLint-derived file/type limits and physical line-length hard failures, applied uniformly with no per-file exemptions.
- Structural split rule: when a file/type crosses a threshold, extract the responsibility into another file/module. Wrapping is only the right fix for a line-length violation, not for an oversized owner.
- Surface reliability: the Mac control surface policy has unit coverage, and live UI smoke testing is available when hardware is safe to command.

## Evidence Boundaries

- `100/100` from a scorer means its documented repository checks are registered and passing. It is not an Apple-issued grade and does not mean 100% code coverage.
- `platformAdapterVectorsVerified` requires shared, iOS, and Mac executable tests to pass.
- `platformBuildParityVerified` requires both app builds to pass.
- `endToEndCrossPlatformBluetoothParityVerified` remains false unless a dedicated iPhone-plus-Mac live hardware run is implemented and executed.
- Coverage is diagnostic. The suite records it to show untested areas rather than using a percentage that can be gamed.
- Compiler/tool warnings are preserved per step. `warningFree` covers every tool, while `projectWarningFree` distinguishes project-source warnings from warnings emitted by external toolchain scripts.

This follows Apple’s recommended test-pyramid approach: many isolated unit tests, fewer integration tests, and UI tests for critical user workflows. See [Testing in Xcode](https://developer.apple.com/documentation/xcode/testing), [Adding tests to an Xcode project](https://developer.apple.com/documentation/xcode/adding-tests-to-your-xcode-project), and [organizing tests with test plans](https://developer.apple.com/documentation/xcode/organizing-tests-to-improve-feedback).
