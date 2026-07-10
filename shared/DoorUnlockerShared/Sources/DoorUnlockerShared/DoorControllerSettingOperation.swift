public enum DoorControllerSettingOperation: Equatable, Sendable {
    case autoLockTimeout(Int)
    case servoAngles(DoorServoAngles)
    case lockName(String)
    case deviceDisplayName(String)

    public var failureTitle: String {
        switch self {
        case .autoLockTimeout:
            return "Auto-lock not set"
        case .servoAngles:
            return "Servo angles not set"
        case .lockName:
            return "Lock name not set"
        case .deviceDisplayName:
            return "Device name not set"
        }
    }
}
