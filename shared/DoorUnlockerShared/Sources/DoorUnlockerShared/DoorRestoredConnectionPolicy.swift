import Foundation

public enum DoorRestoredTransportState: Equatable, Sendable {
    case connected
    case connecting
    case disconnected
}

public enum DoorRestoredTransportAction: Equatable, Sendable {
    case reuseAndValidate
    case awaitConnection
    case connect
}

public struct DoorRestoredConnectionPolicy: Sendable {
    public static let validationTimeout: TimeInterval = 2

    public static func action(for state: DoorRestoredTransportState) -> DoorRestoredTransportAction {
        switch state {
        case .connected:
            return .reuseAndValidate
        case .connecting:
            return .awaitConnection
        case .disconnected:
            return .connect
        }
    }

    public static func shouldForceCleanReconnect(
        validationExpired: Bool,
        receivedFreshBootSession: Bool,
        isTransportConnected: Bool
    ) -> Bool {
        validationExpired && !receivedFreshBootSession && isTransportConnected
    }
}
