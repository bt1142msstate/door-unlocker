import Foundation

public struct DoorSecureCommandRejection: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case staleNonce
        case untrusted
        case busy
        case other
    }

    public let rawReason: String
    public let kind: Kind

    public init(rawReason: String) {
        let trimmedReason = rawReason.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedReason = trimmedReason.lowercased()
        self.rawReason = trimmedReason

        switch normalizedReason {
        case "bad_nonce", "missing_nonce":
            kind = .staleNonce
        case "bad_signature", "unpaired":
            kind = .untrusted
        case let reason where reason.contains("busy"):
            kind = .busy
        default:
            kind = .other
        }
    }

    public var requiresFreshNonce: Bool {
        kind == .staleNonce
    }

    public var invalidatesTrust: Bool {
        kind == .untrusted
    }
}

public enum DoorControllerSettingRejectionAction: Equatable, Sendable {
    case none
    case retry(DoorControllerSettingOperation)
    case fail(DoorControllerSettingOperation, reason: String)
}

public struct DoorControllerSettingConfirmationState: Equatable, Sendable {
    public private(set) var operation: DoorControllerSettingOperation?

    public init(operation: DoorControllerSettingOperation? = nil) {
        self.operation = operation
    }

    public mutating func begin(_ operation: DoorControllerSettingOperation) {
        self.operation = operation
    }

    @discardableResult
    public mutating func complete(_ operation: DoorControllerSettingOperation) -> Bool {
        guard self.operation == operation else { return false }
        self.operation = nil
        return true
    }

    public mutating func reject(_ rejection: DoorSecureCommandRejection) -> DoorControllerSettingRejectionAction {
        guard let operation else { return .none }
        self.operation = nil
        if rejection.requiresFreshNonce {
            return .retry(operation)
        }
        return .fail(operation, reason: rejection.rawReason)
    }
}

public enum DoorControllerSettingConfirmationPolicy {
    // Controller settings are persisted before the final state is published.
    // Replaying the complete snapshot after the observed flash-write window
    // recovers a notification omitted by CoreBluetooth without guessing state.
    public static let stateReadDelayNanoseconds: UInt64 = 4_250_000_000
    public static let completionGraceNanoseconds: UInt64 = 1_750_000_000
    public static let remoteSnapshotReplayDelayNanoseconds: UInt64 = 4_250_000_000
    public static let remoteApplyVisibilityNanoseconds: UInt64 = 6_000_000_000
    public static let controllerIssuedNonceReadDelayNanoseconds: UInt64 = 60_000_000
    public static let explicitNonceFallbackDelayNanoseconds: UInt64 = 240_000_000
}
