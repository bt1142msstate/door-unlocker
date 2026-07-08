# Modularity Scoring

Apple does not provide a first-party numeric "low coupling / high modularity" score for SwiftUI apps. Xcode Analyze is still part of our quality pass, but Apple positions it as bug, security, and logic-issue detection rather than an architecture metric. Apple also points developers toward Swift Package targets/modules as a real boundary for reusable code.

This repo therefore uses `script/score_modularity.py` as a project-specific scoring gate. It is intentionally repeatable and transparent.

## Basis

- Apple Xcode validation: build, test, and use Xcode Analyze where applicable.
- Apple/Swift module boundaries: shared reusable code should move into package targets when it is stable enough to be shared.
- SwiftLint-style size pressure: SwiftLint's default metrics include `file_length` and `type_body_length`, with type bodies warning around 250 lines and erroring around 350 lines.
- Coupling/cohesion theory: CK metrics popularized coupling between objects and lack of cohesion, while Martin-style package metrics popularized dependency direction and instability.

## What The Score Measures

- `ui-file-size`: SwiftUI and app-boundary files should stay small enough to review.
- `root-composition`: `ContentView` should be a composition root, not a full screen controller.
- `feature-folders`: major UI features should have explicit folders.
- `type-file-naming`: primary types should generally match filenames.
- `computed-view-sprawl`: non-trivial SwiftUI sections should become dedicated `View` types instead of many computed `some View` helpers.
- `wide-dependencies`: leaf views should avoid observing the whole controller/store when explicit values and callbacks will do. Feature adapter files may still observe the controller/store, but they are reported as `adapterBoundaryFiles` so the surface area stays visible.
- `module-boundaries`: real target/package boundaries should exist for code that can compile or test independently without pulling in the full app.
- `layering`: SwiftUI view files should not contain BLE, file, process, networking, crypto, or dispatch ownership.
- `shared-protocol-codec`: secure command packet encoding must live in the shared package, not duplicated separately in the iOS and Mac apps.
- `shared-controller-policy`: safe servo limits, auto-lock limits, proximity signal/radius clamps, distance formatting, and name sanitizing should live in the shared package or be exposed through the Mac core model, not duplicated in each app.
- `independent-testability`: protocol parsing, secure command encoding, and Mac core model behavior should be testable in package tests without launching the apps.

The script reports three explicit dimensions:

- `highModularity`: file size, composition roots, feature folders, type/file naming, view helper sprawl, and target/package boundaries.
- `lowCoupling`: leaf-wide dependency count, view-layer isolation, shared protocol ownership, shared controller policy ownership, and state-owner pressure.
- `independentTestability`: independently compiled modules, CLI/core boundaries, shared protocol tests, shared policy tests, and package test coverage for reusable logic.

## State Owner Risk

The BLE controller and Mac admin store are hardware/session state owners. They are reported separately as `stateOwnerRisks` because making them disappear from one file without a careful service split can increase access level leakage and make the code less safe. A high state-owner risk is still technical debt, but it should be handled as a focused service extraction, not mixed into a UI refactor.

## Gate

Run:

```sh
python3 script/quality_suite.py
python3 script/score_modularity.py --threshold 95
python3 script/score_modularity.py --threshold 95 --json
python3 script/score_modularity.py --threshold 95 --write-graph docs/dependency-graph.md
python3 script/score_maintainability.py --threshold 90
```

For this project, the full suite should be the default pre-beta check. The modularity gate requires the overall score and every dimension score to clear the threshold. `95` means the apps have strong beta-level modularity and independently testable shared/core boundaries. State-owner risks must still be reviewed before calling a release production-grade.

The maintainability gate is separate from the architecture score. It uses SwiftLint-derived file/type line-count limits plus explicit legacy budgets so new work cannot quietly recreate oversized files.

Current score:

- iOS: `96.6/100` overall, `96.7` high modularity, `95.5` low coupling, `100.0` independent testability.
- Mac: `98.9/100` overall, `100.0` high modularity, `96.7` low coupling, `100.0` independent testability.

The remaining ceiling is `state-owner-pressure`: `DoorUnlockerController` and `DoorAdminStore` are still large hardware/session owners. They are acceptable for this beta gate because the UI leaves, shared protocol codec, shared controller policy, parser logic, Mac core models, and CLI are isolated, but they remain the next major architecture target.

## Dependency Graph

The generated graph lives at `docs/dependency-graph.md`. It shows the app targets, shared package, Mac core library, CLI, tests, and third-party package edges. The important independent compile/test boundaries today are:

- `DoorUnlockerShared`: shared parser/model library with its own test target.
- `DoorUnlockerCore`: Mac reusable core library with its own test target.
- `DoorUnlockerAdmin`: Mac executable depending on core instead of owning all logic directly.
- `door-unlocker`: CLI executable depending on core, useful for automation and smoke checks without launching the full Mac UI.
- `DoorUnlockerWidget`: iOS extension target separated from the iOS app target.

The shared package currently has independent tests for controller state parsing, secure command packet encoding, and controller policy limits. The Mac core package has independent tests for controller status/device-count behavior.
