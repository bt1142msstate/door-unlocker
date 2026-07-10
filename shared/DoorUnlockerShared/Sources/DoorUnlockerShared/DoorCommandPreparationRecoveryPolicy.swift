public enum DoorCommandPreparationRecoveryAction: Equatable, Sendable {
    case idle
    case requestNonce
    case reconnect
}

public enum DoorCommandPreparationRecoveryPolicy {
    public static let defaultMaximumNonceRequests = 4

    public static func action(
        needsFreshNonce: Bool,
        hasQueuedCommand: Bool,
        completedNonceRequests: Int,
        maximumNonceRequests: Int = defaultMaximumNonceRequests
    ) -> DoorCommandPreparationRecoveryAction {
        guard needsFreshNonce else { return .idle }
        guard hasQueuedCommand else { return .requestNonce }

        let requestLimit = max(1, maximumNonceRequests)
        return completedNonceRequests >= requestLimit ? .reconnect : .requestNonce
    }
}
