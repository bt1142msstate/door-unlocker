import Foundation

public enum DoorFirmwareRecoveryIdentity {
    private static let normalNameFragments = ["doorunlocker-xiao", "doorunlockerxiao"]
    private static let bootloaderNameFragments = ["dfu", "adadfu", "dfutarg"]

    public static func isNormalController(name: String?, advertisesControllerService: Bool) -> Bool {
        if advertisesControllerService {
            return true
        }
        guard let normalizedName = name?
            .replacingOccurrences(of: " ", with: "")
            .lowercased() else {
            return false
        }
        return normalNameFragments.contains { normalizedName.contains($0) }
            && !bootloaderNameFragments.contains { normalizedName.contains($0) }
    }
}
