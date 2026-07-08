import XCTest
@testable import DoorUnlockerCore

final class DoorControlSurfacePolicyTests: XCTestCase {
    func testDisablesWhenControllerCannotReceiveCommands() {
        let snapshot = DoorControlSurfaceSnapshot(
            canSendDoorCommand: false,
            isBusy: false,
            isConnectedByUSB: false,
            isWirelessReady: false,
            isDoorCommandQueued: false,
            isApplyingControllerSetting: false,
            isFirmwareUpdateRunning: false
        )

        XCTAssertTrue(DoorControlSurfacePolicy.isActionDisabled(snapshot))
    }

    func testKeepsSurfaceEnabledWhenUSBIsBusyButWirelessIsReady() {
        let snapshot = DoorControlSurfaceSnapshot(
            canSendDoorCommand: true,
            isBusy: true,
            isConnectedByUSB: true,
            isWirelessReady: true,
            isDoorCommandQueued: false,
            isApplyingControllerSetting: false,
            isFirmwareUpdateRunning: false
        )

        XCTAssertFalse(DoorControlSurfacePolicy.isActionDisabled(snapshot))
        XCTAssertTrue(DoorControlSurfacePolicy.shouldPreferWirelessDoorCommand(snapshot))
    }

    func testDisablesWhenUSBIsBusyAndWirelessCannotBypassIt() {
        let snapshot = DoorControlSurfaceSnapshot(
            canSendDoorCommand: true,
            isBusy: true,
            isConnectedByUSB: true,
            isWirelessReady: false,
            isDoorCommandQueued: false,
            isApplyingControllerSetting: false,
            isFirmwareUpdateRunning: false
        )

        XCTAssertTrue(DoorControlSurfacePolicy.isActionDisabled(snapshot))
        XCTAssertFalse(DoorControlSurfacePolicy.shouldPreferWirelessDoorCommand(snapshot))
    }

    func testQueuedDoorCommandDoesNotFreezeControlSurface() {
        let snapshot = DoorControlSurfaceSnapshot(
            canSendDoorCommand: true,
            isBusy: false,
            isConnectedByUSB: false,
            isWirelessReady: true,
            isDoorCommandQueued: true,
            isApplyingControllerSetting: false,
            isFirmwareUpdateRunning: false
        )

        XCTAssertFalse(DoorControlSurfacePolicy.isActionDisabled(snapshot))
    }

    func testSettingsAndFirmwareStillBlockDoorSurface() {
        let settingSnapshot = DoorControlSurfaceSnapshot(
            canSendDoorCommand: true,
            isBusy: true,
            isConnectedByUSB: true,
            isWirelessReady: true,
            isDoorCommandQueued: false,
            isApplyingControllerSetting: true,
            isFirmwareUpdateRunning: false
        )
        let firmwareSnapshot = DoorControlSurfaceSnapshot(
            canSendDoorCommand: true,
            isBusy: false,
            isConnectedByUSB: false,
            isWirelessReady: true,
            isDoorCommandQueued: false,
            isApplyingControllerSetting: false,
            isFirmwareUpdateRunning: true
        )

        XCTAssertTrue(DoorControlSurfacePolicy.isActionDisabled(settingSnapshot))
        XCTAssertTrue(DoorControlSurfacePolicy.isActionDisabled(firmwareSnapshot))
        XCTAssertFalse(DoorControlSurfacePolicy.shouldPreferWirelessDoorCommand(settingSnapshot))
        XCTAssertFalse(DoorControlSurfacePolicy.shouldPreferWirelessDoorCommand(firmwareSnapshot))
    }
}
