public enum DoorStartupSnapshotAction: Equatable, Sendable {
    case requestImmediately
    case waitForTransport
    case skip
}

public struct DoorStartupSnapshotPolicy: Sendable {
    public static func action(
        isBluetoothAvailable: Bool,
        isGattReady: Bool,
        areStateNotificationsActive: Bool,
        supportsCriticalSnapshot: Bool,
        hasCurrentCriticalSnapshot: Bool,
        isFirmwareUpdateActive: Bool
    ) -> DoorStartupSnapshotAction {
        if !supportsCriticalSnapshot || hasCurrentCriticalSnapshot || isFirmwareUpdateActive {
            return .skip
        }
        guard isBluetoothAvailable, isGattReady, areStateNotificationsActive else {
            return .waitForTransport
        }
        return .requestImmediately
    }
}
