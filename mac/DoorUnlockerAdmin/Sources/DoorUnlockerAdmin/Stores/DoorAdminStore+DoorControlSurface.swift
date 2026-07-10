import DoorUnlockerCore
import DoorUnlockerShared

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

    var doorControlPresentation: DoorControlPresentation {
        DoorControlPresentationPolicy.presentation(
            for: DoorControlPresentationInput(
                servoState: status.bleState,
                isUnlocked: status.isUnlocked,
                canAcceptDoorCommand: canSendDoorCommand,
                isBusy: isBusy,
                isApplyingControllerSetting: isApplyingControllerSetting,
                isFirmwareUpdateBlockingDoorControl: isFirmwareUpdateRunning,
                isDoorCommandQueuedForSecureLink: isDoorCommandQueued,
                isDoorCommandReady: isWirelessDoorCommandReady || isConnected,
                activationVerb: .click,
                controllerSettingApplyTitle: controllerSettingApplyTitle,
                firmwareUpdateActionTitle: "Updating firmware...",
                queuedDoorCommandActionTitle: queuedDoorCommandActionTitle
            )
        )
    }

    var autoLockRange: ClosedRange<Int> {
        ControllerStatus.autoLockRange
    }

    var servoAngleRange: ClosedRange<Int> {
        status.servoAngleRange
    }
}
