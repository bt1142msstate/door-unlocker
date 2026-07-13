import Foundation

public enum DoorFirmwarePackageProfile: String, Equatable, Sendable {
    case factoryCompatible = "factory-compatible"
    case signed = "signed-fast"

    public static func select(forBootloaderNamed name: String?) -> Self {
        DoorFirmwareDfuTuning.isOptimizedBootloaderName(name)
            ? .signed
            : .factoryCompatible
    }

    public static func resolvedBootloaderName(
        advertisedLocalName: String?,
        cachedPeripheralName: String?
    ) -> String? {
        let advertised = advertisedLocalName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let advertised, !advertised.isEmpty {
            return advertised
        }
        let cached = cachedPeripheralName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return cached?.isEmpty == false ? cached : nil
    }

    public static func primaryPackageCanSatisfySignedProfile(fileName: String) -> Bool {
        let normalized = fileName.lowercased()
        return normalized.contains("signed-dfu")
            || normalized.contains("bootloader-dfu")
    }

    public static func stagedFileName(for sourceFileName: String) -> String {
        primaryPackageCanSatisfySignedProfile(fileName: sourceFileName)
            ? sourceFileName
            : "DoorUnlockerXiao-dfu.zip"
    }
}
