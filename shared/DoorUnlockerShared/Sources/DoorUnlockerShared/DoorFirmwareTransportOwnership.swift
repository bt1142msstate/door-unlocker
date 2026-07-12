import Foundation

public enum DoorFirmwareTransportOwnership {
    public static func isDfuTransportActive(
        isUpdateRunning: Bool,
        entryCommandSent: Bool,
        hasPendingPackage: Bool
    ) -> Bool {
        isUpdateRunning && (entryCommandSent || !hasPendingPackage)
    }
}
