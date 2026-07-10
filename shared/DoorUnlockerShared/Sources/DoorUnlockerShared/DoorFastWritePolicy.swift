public enum DoorFastWriteAction: Equatable, Sendable {
    case sendNow
    case waitForCapacity
    case unsupported
}

public enum DoorFastWritePolicy {
    public static func action(
        supportsWriteWithoutResponse: Bool,
        payloadFits: Bool,
        canSendWriteWithoutResponse: Bool
    ) -> DoorFastWriteAction {
        guard supportsWriteWithoutResponse, payloadFits else { return .unsupported }
        return canSendWriteWithoutResponse ? .sendNow : .waitForCapacity
    }
}

public enum DoorReliableWriteAction: Equatable, Sendable {
    case writeWithResponse
    case writeWithoutResponse
    case unsupported
}

public enum DoorReliableWritePolicy {
    public static func action(
        supportsWriteWithResponse: Bool,
        supportsWriteWithoutResponse: Bool,
        canSendWriteWithoutResponse: Bool
    ) -> DoorReliableWriteAction {
        if supportsWriteWithResponse {
            return .writeWithResponse
        }
        if supportsWriteWithoutResponse && canSendWriteWithoutResponse {
            return .writeWithoutResponse
        }
        return .unsupported
    }
}
