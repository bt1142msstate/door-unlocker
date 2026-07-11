import XCTest
@testable import DoorUnlockerShared

final class DoorQueuedCommandDispatchPolicyTests: XCTestCase {
    func testDiscardsQueuedCopyOfCommandAlreadyInFlight() {
        XCTAssertEqual(
            DoorQueuedCommandDispatchPolicy.action(
                queuedDoorCommand: .unlock,
                inFlightDoorCommand: .unlock
            ),
            .discardAlreadyInFlight
        )
    }

    func testDispatchesDifferentQueuedCommand() {
        XCTAssertEqual(
            DoorQueuedCommandDispatchPolicy.action(
                queuedDoorCommand: .lock,
                inFlightDoorCommand: .unlock
            ),
            .dispatch
        )
    }

    func testDispatchesWhenNoDoorCommandIsQueuedOrInFlight() {
        XCTAssertEqual(
            DoorQueuedCommandDispatchPolicy.action(
                queuedDoorCommand: nil,
                inFlightDoorCommand: .unlock
            ),
            .dispatch
        )
        XCTAssertEqual(
            DoorQueuedCommandDispatchPolicy.action(
                queuedDoorCommand: .unlock,
                inFlightDoorCommand: nil
            ),
            .dispatch
        )
    }
}
