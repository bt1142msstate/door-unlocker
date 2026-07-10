import XCTest
@testable import DoorUnlockerShared

final class DoorControllerSettingOperationTests: XCTestCase {
    func testOperationsRetainTheirTypedValues() {
        XCTAssertEqual(DoorControllerSettingOperation.autoLockTimeout(30), .autoLockTimeout(30))
        XCTAssertEqual(
            DoorControllerSettingOperation.servoAngles(DoorServoAngles(lockAngle: 90, unlockAngle: 10)),
            .servoAngles(DoorServoAngles(lockAngle: 90, unlockAngle: 10))
        )
        XCTAssertEqual(DoorControllerSettingOperation.lockName("Front Door"), .lockName("Front Door"))
        XCTAssertEqual(DoorControllerSettingOperation.deviceDisplayName("iPhone Air"), .deviceDisplayName("iPhone Air"))
    }

    func testFailureTitlesAreUserFacing() {
        XCTAssertEqual(DoorControllerSettingOperation.autoLockTimeout(30).failureTitle, "Auto-lock not set")
        XCTAssertEqual(DoorControllerSettingOperation.servoAngles(.init(lockAngle: 90, unlockAngle: 10)).failureTitle, "Servo angles not set")
        XCTAssertEqual(DoorControllerSettingOperation.lockName("Front Door").failureTitle, "Lock name not set")
        XCTAssertEqual(DoorControllerSettingOperation.deviceDisplayName("iPhone Air").failureTitle, "Device name not set")
    }

}
