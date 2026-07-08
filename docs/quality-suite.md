# Quality Suite

`script/quality_suite.py` is the project-level gate for release changes. It combines the architecture scores, size limits, independently compiled tests, and app builds into one repeatable command.

## Default Suite

Run:

```sh
python3 script/quality_suite.py
```

The default suite runs:

- maintainability size/length gate: `script/score_maintainability.py --threshold 90`;
- low coupling, high modularity, and independence gate: `script/score_modularity.py --threshold 95`;
- iOS/Mac shared parity gate: `script/score_shared_parity.py --threshold 95`;
- shared package tests: `swift test --package-path shared/DoorUnlockerShared`;
- Mac core/admin package tests: `swift test --package-path mac/DoorUnlockerAdmin`;
- iOS generic build with signing disabled;
- Mac app build/verify.

It writes a machine-readable report to `docs/quality-suite-last-run.json`.

## Fast Suite

Run:

```sh
python3 script/quality_suite.py --fast
```

This keeps the score gates and independent package tests, but skips the app builds. Use this while refactoring small modules.

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
- Shared parity: cross-platform ownership for secure commands, controller rules, state parsing, control-surface presentation, and name normalization.
- Independence: shared package tests, Mac core tests, CLI/core boundaries, parser/codecs/policy tests, and app builds that do not depend on a live controller.
- Size and length: SwiftLint-derived file/type limits, physical line-length hard failures, plus ratcheted legacy budgets for the two hardware/session owners.
- Structural split rule: when a file/type crosses a threshold, extract the responsibility into another file/module. Wrapping is only the right fix for a line-length violation, not for an oversized owner.
- Surface reliability: the Mac control surface policy has unit coverage, and live UI smoke testing is available when hardware is safe to command.
