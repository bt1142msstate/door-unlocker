public enum DoorCommand: String, CaseIterable, Equatable, Hashable, Sendable {
    case unlock = "UNLOCK"
    case lock = "LOCK"

    public var commandText: String { rawValue }

    public var transitionState: String {
        self == .unlock ? "unlocking" : "locking"
    }

    public var targetIsUnlocked: Bool {
        self == .unlock
    }

    public var inverse: DoorCommand {
        self == .unlock ? .lock : .unlock
    }

    public static func preparationOrder(
        preferred: DoorCommand?,
        isUnlocked: Bool
    ) -> [DoorCommand] {
        let first = preferred ?? (isUnlocked ? .lock : .unlock)
        return [first, first.inverse]
    }
}
