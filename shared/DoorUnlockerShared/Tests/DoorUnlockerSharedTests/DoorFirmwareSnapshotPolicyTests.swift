import XCTest
@testable import DoorUnlockerShared

final class DoorFirmwareSnapshotPolicyTests: XCTestCase {
    func testStopsWhenControllerIsNotReady() {
        XCTAssertEqual(
            DoorFirmwareSnapshotPolicy.action(
                isControllerReady: false,
                hasQueuedDoorCommand: true,
                hasInFlightDoorCommand: true,
                hasControllerSettingOperation: true
            ),
            .stop
        )
    }

    func testDefersForQueuedDoorCommand() {
        XCTAssertEqual(
            DoorFirmwareSnapshotPolicy.action(
                isControllerReady: true,
                hasQueuedDoorCommand: true,
                hasInFlightDoorCommand: false,
                hasControllerSettingOperation: false
            ),
            .deferUntilCommandCompletes
        )
    }

    func testDefersForInFlightDoorCommand() {
        XCTAssertEqual(
            DoorFirmwareSnapshotPolicy.action(
                isControllerReady: true,
                hasQueuedDoorCommand: false,
                hasInFlightDoorCommand: true,
                hasControllerSettingOperation: false
            ),
            .deferUntilCommandCompletes
        )
    }

    func testDefersForControllerSettingOperation() {
        XCTAssertEqual(
            DoorFirmwareSnapshotPolicy.action(
                isControllerReady: true,
                hasQueuedDoorCommand: false,
                hasInFlightDoorCommand: false,
                hasControllerSettingOperation: true
            ),
            .deferUntilCommandCompletes
        )
    }

    func testRequestsWhenReadyAndDoorPathIsIdle() {
        XCTAssertEqual(
            DoorFirmwareSnapshotPolicy.action(
                isControllerReady: true,
                hasQueuedDoorCommand: false,
                hasInFlightDoorCommand: false,
                hasControllerSettingOperation: false
            ),
            .request
        )
    }
}
