import XCTest
@testable import DoorUnlockerShared

final class DoorControllerSettingConfirmationTests: XCTestCase {
    func testRejectReasonsHaveOneSharedClassification() {
        XCTAssertEqual(DoorSecureCommandRejection(rawReason: "bad_nonce").kind, .staleNonce)
        XCTAssertEqual(DoorSecureCommandRejection(rawReason: "missing_nonce").kind, .staleNonce)
        XCTAssertEqual(DoorSecureCommandRejection(rawReason: "bad_signature").kind, .untrusted)
        XCTAssertEqual(DoorSecureCommandRejection(rawReason: "unpaired").kind, .untrusted)
        XCTAssertEqual(DoorSecureCommandRejection(rawReason: "controller busy").kind, .busy)
        XCTAssertEqual(DoorSecureCommandRejection(rawReason: "bad_payload").kind, .other)
    }

    func testOnlyCurrentOperationCanComplete() {
        var state = DoorControllerSettingConfirmationState()
        state.begin(.autoLockTimeout(30))

        XCTAssertFalse(state.complete(.autoLockTimeout(15)))
        XCTAssertEqual(state.operation, .autoLockTimeout(30))
        XCTAssertTrue(state.complete(.autoLockTimeout(30)))
        XCTAssertNil(state.operation)
    }

    func testNewestOperationReplacesOlderOperation() {
        var state = DoorControllerSettingConfirmationState(operation: .autoLockTimeout(15))
        state.begin(.lockName("Front Door"))
        XCTAssertEqual(state.operation, .lockName("Front Door"))
    }

    func testStaleNonceRetriesAndConsumesInFlightOperation() {
        var state = DoorControllerSettingConfirmationState(operation: .servoAngles(.init(lockAngle: 90, unlockAngle: 10)))
        let action = state.reject(DoorSecureCommandRejection(rawReason: "bad_nonce"))

        XCTAssertEqual(action, .retry(.servoAngles(.init(lockAngle: 90, unlockAngle: 10))))
        XCTAssertNil(state.operation)
    }

    func testOtherRejectionFailsAndConsumesInFlightOperation() {
        var state = DoorControllerSettingConfirmationState(operation: .lockName("Front Door"))
        let action = state.reject(DoorSecureCommandRejection(rawReason: "bad_payload"))

        XCTAssertEqual(action, .fail(.lockName("Front Door"), reason: "bad_payload"))
        XCTAssertNil(state.operation)
    }

    func testRejectionWithoutOperationIsIgnored() {
        var state = DoorControllerSettingConfirmationState()
        XCTAssertEqual(
            state.reject(DoorSecureCommandRejection(rawReason: "bad_nonce")),
            .none
        )
    }

    func testConfirmationTimingLeavesRoomForControllerNotification() {
        XCTAssertGreaterThan(DoorControllerSettingConfirmationPolicy.stateReadDelayNanoseconds, 0)
        XCTAssertGreaterThan(DoorControllerSettingConfirmationPolicy.completionGraceNanoseconds, 0)
        XCTAssertGreaterThan(DoorControllerSettingConfirmationPolicy.remoteSnapshotReplayDelayNanoseconds, 0)
        XCTAssertGreaterThan(DoorControllerSettingConfirmationPolicy.remoteApplyVisibilityNanoseconds, 0)
        XCTAssertLessThan(
            DoorControllerSettingConfirmationPolicy.remoteSnapshotReplayDelayNanoseconds,
            DoorControllerSettingConfirmationPolicy.remoteApplyVisibilityNanoseconds
        )
        XCTAssertLessThan(
            DoorControllerSettingConfirmationPolicy.controllerIssuedNonceReadDelayNanoseconds,
            DoorControllerSettingConfirmationPolicy.explicitNonceFallbackDelayNanoseconds
        )
        XCTAssertGreaterThanOrEqual(
            DoorControllerSettingConfirmationPolicy.stateReadDelayNanoseconds
                + DoorControllerSettingConfirmationPolicy.completionGraceNanoseconds,
            6_000_000_000
        )
    }
}
