import DoorUnlockerCore

extension DoorAdminStore {
    var doorControlSurfaceSnapshot: DoorControlSurfaceSnapshot {
        DoorControlSurfaceSnapshot(
            canSendDoorCommand: canSendDoorCommand,
            isBusy: isBusy,
            isConnectedByUSB: isConnected,
            isWirelessReady: isWirelessReady,
            isDoorCommandQueued: isDoorCommandQueued,
            isApplyingControllerSetting: isApplyingControllerSetting,
            isFirmwareUpdateRunning: isFirmwareUpdateRunning
        )
    }

    var isDoorControlSurfaceDisabled: Bool {
        DoorControlSurfacePolicy.isActionDisabled(doorControlSurfaceSnapshot)
    }

    var autoLockRange: ClosedRange<Int> {
        ControllerStatus.autoLockRange
    }

    var servoAngleRange: ClosedRange<Int> {
        status.servoAngleRange
    }
}
