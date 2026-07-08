# Shared Parity Scoring

`script/score_shared_parity.py` keeps the iPhone and Mac apps aligned where they should behave the same.

This is not a visual sameness score. iOS and macOS can use different layouts, controls, copy, and platform-specific affordances. The gate focuses on behavior contracts that should not drift:

- secure command packet encoding and signing inputs;
- controller safety limits and clamping rules;
- controller state parsing and setting text formatting;
- lock/unlock control-surface presentation state;
- device and lock name normalization.

## Run

```sh
python3 script/score_shared_parity.py --threshold 95
```

For machine-readable output:

```sh
python3 script/score_shared_parity.py --json
```

The full suite runs this automatically:

```sh
python3 script/quality_suite.py
```

## Scoring

Each shared contract gets credit only when:

- the shared source exists in `shared/DoorUnlockerShared`;
- the shared package has tests for that contract;
- the iOS app uses the shared implementation;
- the Mac app uses the shared implementation;
- contract-specific drift checks pass, such as no local opcode table or parser prefix duplication.

The project also has a dependency-boundary check to make sure both app targets still depend on `DoorUnlockerShared`.

## Current Contracts

- `secure-command-codec`: `DoorSecureCommandCodec`
- `controller-safety-policy`: `DoorControllerPolicy`
- `controller-state-parsing`: `DoorControllerStateParsing` and `DoorControllerSettingFormatting`
- `control-surface-presentation`: `DoorControlPresentationPolicy`
- `name-normalization`: `DoorNameNormalizer` through shared parser/policy helpers

When a future feature needs parity between iOS and Mac, the preferred path is to move the contract into `DoorUnlockerShared`, add shared tests, then add a scorer contract here.
