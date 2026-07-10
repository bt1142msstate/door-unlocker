# Quality Suite

`script/quality_suite.py` is the project-level gate for release changes. It combines self-tested quality tooling, architecture heuristics, executable tests, coverage evidence, firmware compilation, app builds, and wiring/CAD consistency checks.

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
- shared package tests: `swift test --package-path shared/DoorUnlockerShared`;
- Mac core/admin package tests, including parser and secure-packet adapter vectors;
- iOS host-app adapter tests on an automatically discovered simulator, with `.xcresult` coverage evidence;
- iOS generic build with signing disabled;
- Mac app build/verify;
- bench wiring, breadboard, inline splitter, and Phase 2 dimensional model checks.

It writes a machine-readable report to `docs/quality-suite-last-run.json`, iOS coverage evidence to `docs/ios-test-coverage-last-run.json`, and the raw iOS result bundle to `build/quality/ios-tests.xcresult`.

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
python3 script/quality_suite.py --install-mac
python3 script/quality_suite.py --install-ios
```

`--live-mac-ui` opens the installed Mac app and clicks the main lock/unlock control surface through Accessibility. It is useful for catching UI action-path glitches, but it should only be used when sending a real command is safe.

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
