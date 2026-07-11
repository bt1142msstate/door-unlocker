public enum DoorQueuedCommandDispatchAction: Equatable, Sendable {
    case dispatch
    case discardAlreadyInFlight
}

public enum DoorQueuedCommandDispatchPolicy {
    public static func action(
        queuedDoorCommand: DoorCommand?,
        inFlightDoorCommand: DoorCommand?
    ) -> DoorQueuedCommandDispatchAction {
        guard let queuedDoorCommand,
              queuedDoorCommand == inFlightDoorCommand else {
            return .dispatch
        }
        return .discardAlreadyInFlight
    }
}
