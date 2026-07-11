import XCTest
@testable import DoorUnlockerShared

final class DoorCommandSchedulingPolicyTests: XCTestCase {
    func testDefersWhileControllerIsMoving() {
        XCTAssertTrue(
            DoorCommandSchedulingPolicy.shouldDeferNewCommand(
                isControllerChangingState: true,
                hasInFlightCommand: false
            )
        )
    }

    func testDefersWhileCommandAwaitsConfirmation() {
        XCTAssertTrue(
            DoorCommandSchedulingPolicy.shouldDeferNewCommand(
                isControllerChangingState: false,
                hasInFlightCommand: true
            )
        )
    }

    func testDispatchesOnlyAfterStableConfirmation() {
        XCTAssertTrue(
            DoorCommandSchedulingPolicy.canDispatchQueuedCommand(
                isControllerChangingState: false,
                hasInFlightCommand: false
            )
        )
    }
}
