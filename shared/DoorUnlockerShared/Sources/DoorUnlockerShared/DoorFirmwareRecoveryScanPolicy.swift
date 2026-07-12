public enum DoorFirmwareRecoveryPeripheralRole: Equatable, Sendable {
    case normalController
    case bootloader
    case unrelated
}

public enum DoorFirmwareRecoveryScanAction: Equatable, Sendable {
    case notifyNormalController
    case startBootloaderUpload
    case ignore
}

public enum DoorFirmwareRecoveryScanPolicy {
    public static func action(
        role: DoorFirmwareRecoveryPeripheralRole,
        detectsNormalControllerFirmware: Bool,
        allowsBootloaderUpload: Bool
    ) -> DoorFirmwareRecoveryScanAction {
        switch role {
        case .normalController where detectsNormalControllerFirmware:
            return .notifyNormalController
        case .bootloader where !detectsNormalControllerFirmware || allowsBootloaderUpload:
            return .startBootloaderUpload
        case .normalController, .bootloader, .unrelated:
            return .ignore
        }
    }
}
