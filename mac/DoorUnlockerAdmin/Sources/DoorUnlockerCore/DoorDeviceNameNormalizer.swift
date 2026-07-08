import Foundation
import DoorUnlockerShared

public enum DoorDeviceNameNormalizer {
    public static let maximumDeviceNameLength = 24

    public static func normalized(_ name: String, fallback: String, maximumLength: Int = maximumDeviceNameLength) -> String {
        DoorNameNormalizer.normalized(name, fallback: fallback, maximumLength: maximumLength)
    }
}
