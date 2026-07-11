import Foundation

public enum DoorBluetoothAvailability: String, CaseIterable, Sendable {
    case starting
    case available
    case poweredOff
    case unauthorized
    case unsupported
    case resetting
    case unknown
}

public enum DoorControllerLinkPhase: String, CaseIterable, Sendable {
    case idle
    case scanning
    case connecting
    case discovering
    case restoring
    case connected
    case updatingFirmware
}

public enum DoorControllerSessionPhase: String, CaseIterable, Sendable {
    case starting
    case bluetoothOff
    case permissionNeeded
    case unsupported
    case bluetoothResetting
    case offline
    case scanning
    case connecting
    case discovering
    case restoring
    case pairingRequired
    case authenticating
    case synchronizing
    case preparingSecureControl
    case ready
    case updatingFirmware

    public var isKnownControllerConnectionInProgress: Bool {
        switch self {
        case .connecting, .discovering, .restoring, .authenticating,
             .synchronizing, .preparingSecureControl:
            return true
        default:
            return false
        }
    }
}

public struct DoorControllerSessionFacts: Equatable, Sendable {
    public var bluetooth: DoorBluetoothAvailability
    public var link: DoorControllerLinkPhase
    public var isTransportConnected: Bool
    public var isGattReady: Bool
    public var isTrusted: Bool
    public var isControllerHealthKnown: Bool
    public var isControllerHealthy: Bool
    public var isLinkAuthenticated: Bool
    public var hasCurrentStateSnapshot: Bool
    public var hasFreshCommandMaterial: Bool
    public var canQueueCommand: Bool

    public init(
        bluetooth: DoorBluetoothAvailability,
        link: DoorControllerLinkPhase,
        isTransportConnected: Bool = false,
        isGattReady: Bool = false,
        isTrusted: Bool = false,
        isControllerHealthKnown: Bool = true,
        isControllerHealthy: Bool = true,
        isLinkAuthenticated: Bool = false,
        hasCurrentStateSnapshot: Bool = false,
        hasFreshCommandMaterial: Bool = false,
        canQueueCommand: Bool = false
    ) {
        self.bluetooth = bluetooth
        self.link = link
        self.isTransportConnected = isTransportConnected
        self.isGattReady = isGattReady
        self.isTrusted = isTrusted
        self.isControllerHealthKnown = isControllerHealthKnown
        self.isControllerHealthy = isControllerHealthy
        self.isLinkAuthenticated = isLinkAuthenticated
        self.hasCurrentStateSnapshot = hasCurrentStateSnapshot
        self.hasFreshCommandMaterial = hasFreshCommandMaterial
        self.canQueueCommand = canQueueCommand
    }
}

public struct DoorControllerSessionAssessment: Equatable, Sendable {
    public let phase: DoorControllerSessionPhase
    public let isControllerOnline: Bool
    public let isDisplayedStateAuthoritative: Bool
    public let canDispatchImmediately: Bool
    public let canQueueCommand: Bool

    public static func assess(_ facts: DoorControllerSessionFacts) -> Self {
        let phase = phase(for: facts)
        let online = facts.bluetooth == .available && facts.isTransportConnected
        let authoritative = online &&
            facts.isGattReady &&
            facts.isControllerHealthKnown &&
            facts.isControllerHealthy &&
            facts.hasCurrentStateSnapshot
        let immediate = phase == .ready

        return Self(
            phase: phase,
            isControllerOnline: online,
            isDisplayedStateAuthoritative: authoritative,
            canDispatchImmediately: immediate,
            canQueueCommand: !immediate && facts.canQueueCommand
        )
    }

    private static func phase(for facts: DoorControllerSessionFacts) -> DoorControllerSessionPhase {
        if facts.link == .updatingFirmware {
            return .updatingFirmware
        }

        switch facts.bluetooth {
        case .poweredOff:
            return .bluetoothOff
        case .unauthorized:
            return .permissionNeeded
        case .unsupported:
            return .unsupported
        case .resetting:
            return .bluetoothResetting
        case .starting, .unknown:
            return .starting
        case .available:
            break
        }

        guard facts.isTransportConnected else {
            switch facts.link {
            case .scanning:
                return .scanning
            case .connecting:
                return .connecting
            case .restoring:
                return .restoring
            case .discovering:
                return .discovering
            case .idle, .connected:
                return .offline
            case .updatingFirmware:
                return .updatingFirmware
            }
        }

        guard facts.isGattReady else {
            return .discovering
        }

        guard facts.isTrusted else {
            return .pairingRequired
        }

        guard facts.isControllerHealthKnown, facts.isControllerHealthy else {
            return .synchronizing
        }

        guard facts.isLinkAuthenticated else {
            return .authenticating
        }

        guard facts.hasCurrentStateSnapshot else {
            return .synchronizing
        }

        guard facts.hasFreshCommandMaterial else {
            return .preparingSecureControl
        }

        return .ready
    }
}
