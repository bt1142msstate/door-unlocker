import Foundation
import XCTest
@testable import DoorUnlockerShared

final class DoorAdverseSequenceStressTests: XCTestCase {
    func testCommandSettingNonceAndSnapshotPoliciesUnderRandomizedInterleavings() {
        var random = StressRandom(seed: 0xA11C_E5EED)
        var settingConfirmation = DoorControllerSettingConfirmationState()
        var lastConsumedNonce: Data?

        for step in 0..<500_000 {
            let queuedCommand: DoorCommand? = random.bool() ? (random.bool() ? .lock : .unlock) : nil
            let inFlightCommand: DoorCommand? = random.bool() ? (random.bool() ? .lock : .unlock) : nil
            let changing = random.bool()

            let mayDispatch = DoorCommandSchedulingPolicy.canDispatchQueuedCommand(
                isControllerChangingState: changing,
                hasInFlightCommand: inFlightCommand != nil
            )
            XCTAssertEqual(mayDispatch, !changing && inFlightCommand == nil, "step \(step)")

            let queuedAction = DoorQueuedCommandDispatchPolicy.action(
                queuedDoorCommand: queuedCommand,
                inFlightDoorCommand: inFlightCommand
            )
            if queuedAction == .discardAlreadyInFlight {
                XCTAssertNotNil(queuedCommand, "step \(step)")
                XCTAssertEqual(queuedCommand, inFlightCommand, "step \(step)")
            }

            let snapshotAction = DoorFirmwareSnapshotPolicy.action(
                isControllerReady: random.bool(),
                hasQueuedDoorCommand: queuedCommand != nil,
                hasInFlightDoorCommand: inFlightCommand != nil,
                hasControllerSettingOperation: settingConfirmation.operation != nil
            )
            if snapshotAction == .request {
                XCTAssertNil(queuedCommand, "step \(step)")
                XCTAssertNil(inFlightCommand, "step \(step)")
                XCTAssertNil(settingConfirmation.operation, "step \(step)")
            }

            var nonceValue = random.next().bigEndian
            let nonce = withUnsafeBytes(of: &nonceValue) { Data($0) }
            let accepted = DoorSecureNonceAcceptancePolicy.shouldAccept(
                receivedNonce: nonce,
                lastConsumedNonce: lastConsumedNonce
            )
            XCTAssertEqual(accepted, nonce != lastConsumedNonce, "step \(step)")
            if accepted && random.bool() {
                lastConsumedNonce = nonce
                XCTAssertFalse(
                    DoorSecureNonceAcceptancePolicy.shouldAccept(
                        receivedNonce: nonce,
                        lastConsumedNonce: lastConsumedNonce
                    ),
                    "step \(step)"
                )
            }

            let operation = random.settingOperation()
            switch random.next() % 4 {
            case 0:
                settingConfirmation.begin(operation)
                XCTAssertEqual(settingConfirmation.operation, operation, "step \(step)")
            case 1:
                let current = settingConfirmation.operation
                let completed = settingConfirmation.complete(operation)
                XCTAssertEqual(completed, current == operation, "step \(step)")
                XCTAssertEqual(settingConfirmation.operation, completed ? nil : current, "step \(step)")
            case 2:
                let current = settingConfirmation.operation
                let action = settingConfirmation.reject(
                    DoorSecureCommandRejection(rawReason: random.bool() ? "bad_nonce" : "bad_signature")
                )
                if current == nil {
                    XCTAssertEqual(action, .none, "step \(step)")
                } else {
                    XCTAssertNil(settingConfirmation.operation, "step \(step)")
                }
            default:
                break
            }
        }
    }
}

private struct StressRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state = state &* 2_862_933_555_777_941_757 &+ 3_037_000_493
        return state
    }

    mutating func bool() -> Bool {
        next() & 1 == 0
    }

    mutating func settingOperation() -> DoorControllerSettingOperation {
        switch next() % 4 {
        case 0:
            return .autoLockTimeout(Int(next() % 300) + 1)
        case 1:
            let lock = Int(next() % 120)
            return .servoAngles(DoorServoAngles(lockAngle: lock, unlockAngle: lock + 20))
        case 2:
            return .lockName("Lock \(next() % 64)")
        default:
            return .deviceDisplayName("Device \(next() % 64)")
        }
    }
}
