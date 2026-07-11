import XCTest
@testable import DoorUnlockerShared

final class DoorStartupSnapshotPolicyTests: XCTestCase {
    func testRequestsAsSoonAsGattAndStateNotificationsAreReady() {
        XCTAssertEqual(
            DoorStartupSnapshotPolicy.action(
                isBluetoothAvailable: true,
                isGattReady: true,
                areStateNotificationsActive: true,
                supportsCriticalSnapshot: true,
                hasCurrentCriticalSnapshot: false,
                isFirmwareUpdateActive: false
            ),
            .requestImmediately
        )
    }

    func testWaitsForGattAndNotificationTransport() {
        XCTAssertEqual(
            DoorStartupSnapshotPolicy.action(
                isBluetoothAvailable: true,
                isGattReady: false,
                areStateNotificationsActive: true,
                supportsCriticalSnapshot: true,
                hasCurrentCriticalSnapshot: false,
                isFirmwareUpdateActive: false
            ),
            .waitForTransport
        )
        XCTAssertEqual(
            DoorStartupSnapshotPolicy.action(
                isBluetoothAvailable: true,
                isGattReady: true,
                areStateNotificationsActive: false,
                supportsCriticalSnapshot: true,
                hasCurrentCriticalSnapshot: false,
                isFirmwareUpdateActive: false
            ),
            .waitForTransport
        )
        XCTAssertEqual(
            DoorStartupSnapshotPolicy.action(
                isBluetoothAvailable: false,
                isGattReady: true,
                areStateNotificationsActive: true,
                supportsCriticalSnapshot: true,
                hasCurrentCriticalSnapshot: false,
                isFirmwareUpdateActive: false
            ),
            .waitForTransport
        )
    }

    func testSkipsCurrentSnapshotAndFirmwareUpdateSessions() {
        XCTAssertEqual(
            DoorStartupSnapshotPolicy.action(
                isBluetoothAvailable: true,
                isGattReady: true,
                areStateNotificationsActive: true,
                supportsCriticalSnapshot: true,
                hasCurrentCriticalSnapshot: true,
                isFirmwareUpdateActive: false
            ),
            .skip
        )
        XCTAssertEqual(
            DoorStartupSnapshotPolicy.action(
                isBluetoothAvailable: true,
                isGattReady: true,
                areStateNotificationsActive: true,
                supportsCriticalSnapshot: true,
                hasCurrentCriticalSnapshot: false,
                isFirmwareUpdateActive: true
            ),
            .skip
        )
        XCTAssertEqual(
            DoorStartupSnapshotPolicy.action(
                isBluetoothAvailable: true,
                isGattReady: true,
                areStateNotificationsActive: true,
                supportsCriticalSnapshot: false,
                hasCurrentCriticalSnapshot: false,
                isFirmwareUpdateActive: false
            ),
            .skip
        )
    }
}
