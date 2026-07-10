# Shared Parity Scoring

`script/score_shared_parity.py` checks that iPhone and Mac parity contracts have one shared owner, registered shared tests, platform adapters, and drift guards.

This is not a visual sameness score. iOS and macOS can use different layouts, controls, copy, and platform-specific affordances. The gate focuses on behavior contracts that should not drift:

- secure command packet encoding and signing inputs;
- lock/unlock command identity and fast-payload preparation order;
- fast write dispatch and secure-link recovery decisions;
- controller safety limits and clamping rules;
- controller state parsing and setting text formatting;
- lock/unlock control-surface presentation state;
- device and lock name normalization.
- Nordic DFU scanning, upload, progress, ETA, timeout, and completion transport.

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

The score is a **repository-structure and test-registration heuristic**. It intentionally cannot claim that tests passed. Runtime evidence comes from `swift test` and `xcodebuild test` in the full quality suite.

Each shared contract gets credit only when:

- the shared source exists in `shared/DoorUnlockerShared`;
- the shared package has tests for that contract;
- the iOS app uses the shared implementation;
- the Mac app uses the shared implementation;
- contract-specific drift checks pass, such as no local opcode table or parser prefix duplication.

For secure command and parser adapters, the gate also requires iOS and Mac adapter test declarations. Test discovery ignores declarations inside comments and strings, and the quality-tooling tests prove that missing adapter references and fake tests fail closed.

The project also has a dependency-boundary check to make sure both app targets still depend on `DoorUnlockerShared` and the shared `DoorUnlockerDFU` product.

## Current Contracts

- `secure-command-codec`: `DoorSecureCommandCodec` and `DoorSecureCommandSigningContext`
- `controller-safety-policy`: `DoorControllerPolicy`
- `controller-state-parsing`: `DoorControllerStateParsing` and `DoorControllerSettingFormatting`
- `door-command-model`: `DoorCommand` and its payload-preparation order
- `fast-write-dispatch`: `DoorFastWritePolicy` and `DoorReliableWritePolicy`
- `command-preparation-recovery`: `DoorCommandPreparationRecoveryPolicy`
- `control-surface-presentation`: `DoorControlPresentationPolicy`
- `name-normalization`: `DoorNameNormalizer` through shared parser/policy helpers
- `firmware-dfu-transport`: `DoorFirmwareDfuManager`, `DoorFirmwareDfuTuning`, and `DoorFirmwareProgressEstimation`

Platform code intentionally keeps only the adapters that cannot be shared cleanly: iOS Secure Enclave/Keychain identity storage, Mac signing-key persistence, app lifecycle/background behavior, Mac USB serial administration, and platform-specific SwiftUI.

The full suite runs the same canonical parser inputs and secure packet/opcode expectations through both platform adapters. It still does not claim end-to-end Bluetooth parity unless an opt-in live hardware test explicitly exercises both apps against the controller.

When a future feature needs parity between iOS and Mac, the preferred path is to move the contract into `DoorUnlockerShared`, add shared tests, then add a scorer contract here.
