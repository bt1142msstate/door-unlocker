import XCTest
@testable import DoorUnlockerShared

final class DoorControllerPolicyTests: XCTestCase {
    func testAutoLockAndHoldDurationsClampToSafeRanges() {
        XCTAssertEqual(DoorControllerPolicy.clampedAutoLockSeconds(1), 5)
        XCTAssertEqual(DoorControllerPolicy.clampedAutoLockSeconds(30), 30)
        XCTAssertEqual(DoorControllerPolicy.clampedAutoLockSeconds(500), 120)

        XCTAssertEqual(DoorControllerPolicy.clampedUnlockHoldDurationSeconds(0.1), 0.5)
        XCTAssertEqual(DoorControllerPolicy.clampedUnlockHoldDurationSeconds(1.13), 1.25)
        XCTAssertEqual(DoorControllerPolicy.clampedUnlockHoldDurationSeconds(9.0), 3.0)
    }

    func testServoAnglesClampAndValidate() {
        let clamped = DoorControllerPolicy.clampedServoAngles(
            DoorServoAngles(lockAngle: -20, unlockAngle: 220)
        )

        XCTAssertEqual(clamped, DoorServoAngles(lockAngle: 10, unlockAngle: 170))
        XCTAssertTrue(DoorControllerPolicy.servoAnglesAreValid(DoorServoAngles(lockAngle: 95, unlockAngle: 20)))
        XCTAssertTrue(DoorControllerPolicy.servoAnglesAreValid(DoorServoAngles(lockAngle: 95, unlockAngle: 100)))
        XCTAssertTrue(DoorControllerPolicy.servoAnglesAreValid(DoorServoAngles(lockAngle: 95, unlockAngle: 95)))
        XCTAssertFalse(DoorControllerPolicy.servoAnglesAreValid(DoorServoAngles(lockAngle: 9, unlockAngle: 95)))
    }

    func testLockZoneAndSignalThresholdsClamp() {
        XCTAssertEqual(DoorControllerPolicy.clampedLockZoneRadiusMeters(1), 5)
        XCTAssertEqual(DoorControllerPolicy.clampedLockZoneRadiusMeters(27), 25)
        XCTAssertEqual(DoorControllerPolicy.clampedLockZoneRadiusMeters(400), 150)

        XCTAssertEqual(DoorControllerPolicy.clampedProximityUnlockRSSIThreshold(-100), -82)
        XCTAssertEqual(DoorControllerPolicy.clampedProximityUnlockRSSIThreshold(-60), -60)
        XCTAssertEqual(DoorControllerPolicy.clampedProximityUnlockRSSIThreshold(-20), -45)
    }

    func testDistanceFormattingAndNameSanitizing() {
        XCTAssertEqual(DoorControllerPolicy.formattedDistance(22.4, unit: .meters), "22 m")
        XCTAssertEqual(DoorControllerPolicy.formattedDistance(1400, unit: .meters), "1.4 km")
        XCTAssertEqual(DoorControllerPolicy.formattedDistance(10, unit: .feet), "33 ft")
        XCTAssertEqual(DoorControllerPolicy.sanitizedName("Brandon\u{2019}s\nLock"), "Brandon's Lock")
    }

    func testProximityArmRestoresWithoutRecheckingCurrentZoneContainment() {
        let now = Date(timeIntervalSince1970: 10_000)
        let armedAt = now.addingTimeInterval(-120)

        XCTAssertEqual(
            DoorControllerPolicy.restoredProximityUnlockArmedAt(
                enabled: true,
                hasLockZone: true,
                storedArmedAt: armedAt,
                now: now,
                maximumAge: 12 * 60 * 60
            ),
            armedAt
        )
    }

    func testProximityArmDoesNotRestoreWhenDisabledMissingOrExpired() {
        let now = Date(timeIntervalSince1970: 10_000)
        let armedAt = now.addingTimeInterval(-120)

        XCTAssertNil(DoorControllerPolicy.restoredProximityUnlockArmedAt(
            enabled: false,
            hasLockZone: true,
            storedArmedAt: armedAt,
            now: now,
            maximumAge: 12 * 60 * 60
        ))
        XCTAssertNil(DoorControllerPolicy.restoredProximityUnlockArmedAt(
            enabled: true,
            hasLockZone: false,
            storedArmedAt: armedAt,
            now: now,
            maximumAge: 12 * 60 * 60
        ))
        XCTAssertNil(DoorControllerPolicy.restoredProximityUnlockArmedAt(
            enabled: true,
            hasLockZone: true,
            storedArmedAt: now.addingTimeInterval(-(13 * 60 * 60)),
            now: now,
            maximumAge: 12 * 60 * 60
        ))
    }
}
