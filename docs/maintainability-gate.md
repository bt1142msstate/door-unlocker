# Maintainability Gate

The project now has a line-count gate in `script/score_maintainability.py`. It is meant to keep the apps easy to review, test, and refactor while the hardware-facing state owners are split down over time.

When a file or type crosses a limit, the fix should be structural: extract a focused service, parser, presenter, view, or policy into another file or shared package target. Do not "fix" line-count pressure by deleting useful spacing, collapsing expressions, or stuffing multiple responsibilities onto fewer physical lines.

## Baseline

The limits use SwiftLint's default metric rules as the outside reference:

- `file_length`: warning at 400 lines, error at 1000 lines.
- `type_body_length`: warning at 250 lines, error at 350 lines.
- `function_body_length`: warning at 50 lines, error at 100 lines.
- `cyclomatic_complexity`: warning at 10, error at 20.
- `line_length`: this repo warns above 160 characters and fails above 220 characters.

This repo currently enforces the file, type, and physical line-length limits directly because those are the highest-signal maintainability pressure points in the current SwiftUI/macOS codebase. Function and complexity limits are documented as the next gate to wire in once the large controller/store split begins.

## Gate

Run:

```sh
python3 script/quality_suite.py
python3 script/score_maintainability.py --threshold 90
python3 script/score_maintainability.py --threshold 90 --json
```

The gate fails when:

- the total maintainability score is below `90`;
- a non-legacy Swift file exceeds `1000` lines;
- a non-legacy Swift type exceeds `350` lines;
- a legacy budgeted file grows beyond its current budget.
- any Swift line exceeds `220` characters.

Line-length violations should be fixed by wrapping expressions or extracting names. File/type violations should be fixed by moving coherent behavior into separate files/modules, not by compressing whitespace.

Current score:

- Maintainability: `91.3/100`.
- Swift files scanned: `81`.
- Swift types scanned: `186`.
- Long-line warnings: `17`.
- Hard violations: `0`.

## Legacy Ratchets

Two files are intentionally budgeted because they are hardware/session state owners and should be split through careful service extraction instead of a cosmetic move:

- `ios/DoorUnlockerApp/DoorUnlocker/DoorUnlockerController.swift`: budget `5890` lines.
- `mac/DoorUnlockerAdmin/Sources/DoorUnlockerAdmin/Stores/DoorAdminStore.swift`: budget `3907` lines.

Those files are allowed to remain over the SwiftLint warning threshold for now, but they cannot grow. New work should move behavior out of them into small services, presenters, parsers, codecs, or feature views.

## Scoring Meaning

`90+` means:

- no new oversized app files or types;
- oversized legacy owners are explicitly visible and budget-locked;
- feature UI and CLI responsibilities are split into smaller files;
- the modularity gate still owns the dependency graph and independent test boundaries.

This is a beta-grade maintainability gate, not a claim that the two state owners are finished architecture.
