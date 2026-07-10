# Maintainability Gate

The project has a line-count gate in `script/score_maintainability.py`. It keeps the apps easy to review, test, and refactor by applying one set of limits to every Swift source file and type.

When a file or type crosses a limit, the fix should be structural: extract a focused service, parser, presenter, view, or policy into another file or shared package target. Do not "fix" line-count pressure by deleting useful spacing, collapsing expressions, or stuffing multiple responsibilities onto fewer physical lines.

## Baseline

The limits use SwiftLint's default metric rules as the outside reference:

- `file_length`: warning at 400 lines, error at 1000 lines.
- `type_body_length`: warning at 250 lines, error at 350 lines.
- `function_body_length`: warning at 50 lines, error at 100 lines.
- `cyclomatic_complexity`: warning at 10, error at 20.
- `line_length`: this repo warns above 160 characters and fails above 220 characters.

This repo currently enforces the file, type, and physical line-length limits directly because those are the highest-signal maintainability pressure points in the current SwiftUI/macOS codebase. Function and complexity limits remain documented reference points for future gate expansion.

## Gate

Run:

```sh
python3 script/quality_suite.py
python3 script/score_maintainability.py --threshold 90
python3 script/score_maintainability.py --threshold 90 --json
```

The gate fails when:

- the total maintainability score is below `90`;
- any Swift file exceeds `1000` lines;
- any Swift type exceeds `350` lines;
- any Swift line exceeds `220` characters.

Line-length violations should be fixed by wrapping expressions or extracting names. File/type violations should be fixed by moving coherent behavior into separate files or modules, not by compressing whitespace.

## No Exemptions

The iOS controller and Mac store are split into feature-focused extension files. Neither receives a special budget, and future files cannot opt out of the standard hard limits. New behavior should continue to land in small services, presenters, parsers, codecs, or feature views.

## Scoring Meaning

`90+` means:

- no oversized app files or types;
- every file and type is held to the same hard limit;
- feature UI and CLI responsibilities are split into smaller files;
- the modularity gate still owns the dependency graph and independent test boundaries.

This is a structural guardrail, not a substitute for behavior tests or architecture review. The latest measured score is written to `docs/quality-suite-last-run.json` by the full quality suite.
