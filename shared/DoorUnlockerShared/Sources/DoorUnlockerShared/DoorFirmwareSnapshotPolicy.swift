import Foundation

public enum DoorFirmwareSnapshotAction: Equatable, Sendable {
    case stop
    case deferUntilCommandCompletes
    case request
}

public enum DoorFirmwareSnapshotPolicy {
    public static func action(
        isControllerReady: Bool,
        hasQueuedDoorCommand: Bool,
        hasInFlightDoorCommand: Bool,
        hasControllerSettingOperation: Bool
    ) -> DoorFirmwareSnapshotAction {
        guard isControllerReady else { return .stop }
        guard !hasQueuedDoorCommand,
              !hasInFlightDoorCommand,
              !hasControllerSettingOperation else {
            return .deferUntilCommandCompletes
        }
        return .request
    }
}
