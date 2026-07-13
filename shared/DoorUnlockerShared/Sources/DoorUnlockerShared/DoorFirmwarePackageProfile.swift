public enum DoorFirmwarePackageProfile: String, Equatable, Sendable {
    case factoryCompatible = "factory-compatible"
    case signed = "signed-fast"

    public static func select(forBootloaderNamed name: String?) -> Self {
        name == DoorFirmwareDfuTuning.optimizedBootloaderName
            ? .signed
            : .factoryCompatible
    }
}
