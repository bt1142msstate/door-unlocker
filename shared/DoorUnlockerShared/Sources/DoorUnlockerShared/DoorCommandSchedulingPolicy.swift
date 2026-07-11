public enum DoorCommandSchedulingPolicy {
    public static func shouldDeferNewCommand(
        isControllerChangingState: Bool,
        hasInFlightCommand: Bool
    ) -> Bool {
        isControllerChangingState || hasInFlightCommand
    }

    public static func canDispatchQueuedCommand(
        isControllerChangingState: Bool,
        hasInFlightCommand: Bool
    ) -> Bool {
        !shouldDeferNewCommand(
            isControllerChangingState: isControllerChangingState,
            hasInFlightCommand: hasInFlightCommand
        )
    }
}
