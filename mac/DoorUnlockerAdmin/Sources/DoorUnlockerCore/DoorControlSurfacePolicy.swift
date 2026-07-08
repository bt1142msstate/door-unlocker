import Foundation

public struct DoorControlSurfaceSnapshot: Equatable {
    public var canSendDoorCommand: Bool
    public var isBusy: Bool
    public var isConnectedByUSB: Bool
    public var isWirelessReady: Bool
    public var isDoorCommandQueued: Bool
    public var isApplyingControllerSetting: Bool
    public var isFirmwareUpdateRunning: Bool

    public init(
        canSendDoorCommand: Bool,
        isBusy: Bool,
        isConnectedByUSB: Bool,
        isWirelessReady: Bool,
        isDoorCommandQueued: Bool,
        isApplyingControllerSetting: Bool,
        isFirmwareUpdateRunning: Bool
    ) {
        self.canSendDoorCommand = canSendDoorCommand
        self.isBusy = isBusy
        self.isConnectedByUSB = isConnectedByUSB
        self.isWirelessReady = isWirelessReady
        self.isDoorCommandQueued = isDoorCommandQueued
        self.isApplyingControllerSetting = isApplyingControllerSetting
        self.isFirmwareUpdateRunning = isFirmwareUpdateRunning
    }
}

public enum DoorControlSurfacePolicy {
    public static func isActionDisabled(_ snapshot: DoorControlSurfaceSnapshot) -> Bool {
        guard snapshot.canSendDoorCommand else { return true }
        guard !snapshot.isApplyingControllerSetting else { return true }
        guard !snapshot.isFirmwareUpdateRunning else { return true }

        if snapshot.isBusy {
            return !canBypassBusyWorkForDoorCommand(snapshot)
        }

        return false
    }

    public static func shouldPreferWirelessDoorCommand(_ snapshot: DoorControlSurfaceSnapshot) -> Bool {
        snapshot.isConnectedByUSB &&
            snapshot.isBusy &&
            snapshot.isWirelessReady &&
            !snapshot.isApplyingControllerSetting &&
            !snapshot.isFirmwareUpdateRunning
    }

    private static func canBypassBusyWorkForDoorCommand(_ snapshot: DoorControlSurfaceSnapshot) -> Bool {
        shouldPreferWirelessDoorCommand(snapshot) || (!snapshot.isConnectedByUSB && snapshot.isWirelessReady)
    }
}
