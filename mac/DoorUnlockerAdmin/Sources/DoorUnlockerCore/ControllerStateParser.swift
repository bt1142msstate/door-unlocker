import Foundation
import DoorUnlockerShared

public typealias LastUnlockRecord = DoorLastUnlockRecord

public struct ControllerConnectionsPayload: Equatable, Hashable {
    public let count: Int
    public let max: Int
    public let devices: [ConnectedControllerDevice]

    public init(count: Int, max: Int, devices: [ConnectedControllerDevice]) {
        self.count = count
        self.max = max
        self.devices = devices
    }
}

public enum ControllerStateParser {
    public static func lockName(from rawState: String, fallback: String) -> String? {
        DoorControllerStateParsing.lockName(from: rawState, fallback: fallback)
    }

    public static func firmwareVersion(from rawState: String) -> String? {
        DoorControllerStateParsing.firmwareVersion(from: rawState)
    }

    public static func firmwareUpdateState(from rawState: String) -> String? {
        DoorControllerStateParsing.firmwareUpdateState(from: rawState)
    }

    public static func firmwareUpdateAnnouncement(
        from rawState: String
    ) -> (state: String, updaterName: String?)? {
        DoorControllerStateParsing.firmwareUpdateAnnouncement(from: rawState)
    }

    public static func fastCommandNonce(from rawState: String) -> Data? {
        DoorControllerStateParsing.fastCommandNonce(from: rawState)
    }

    public static func fastCommandRejectReason(from rawState: String) -> String? {
        DoorControllerStateParsing.fastCommandRejectReason(from: rawState)
    }

    public static func settingApplying(from rawState: String) -> (kind: String, value: String?)? {
        DoorControllerStateParsing.settingApplying(from: rawState)
    }

    public static func servoAngles(from rawState: String) -> ServoAngles? {
        guard let angles = DoorControllerStateParsing.servoAngles(from: rawState) else { return nil }
        return ServoAngles(lockAngle: angles.lockAngle, unlockAngle: angles.unlockAngle)
    }

    public static func lastUnlockRecord(from rawState: String) -> LastUnlockRecord? {
        DoorControllerStateParsing.lastUnlockRecord(from: rawState)
    }

    public static func connectedDevices(from rawState: String) -> ControllerConnectionsPayload? {
        guard let payload = DoorControllerStateParsing.connectedDevices(from: rawState) else { return nil }
        let devices = payload.devices.map { device in
            ConnectedControllerDevice(
                slot: device.slot,
                handle: "wireless-\(device.slot)",
                name: device.name,
                isTrustedName: true
            )
        }
        return ControllerConnectionsPayload(count: payload.count, max: payload.max, devices: devices)
    }

    public static func dataFromHex(_ hex: String, expectedByteCount: Int) -> Data? {
        DoorControllerStateParsing.dataFromHex(hex, expectedByteCount: expectedByteCount)
    }

    public static func isTrustedDeviceIdentifier(_ value: String) -> Bool {
        DoorControllerStateParsing.isTrustedDeviceIdentifier(value)
    }
}

public enum ControllerSettingFormatter {
    public static func title(for kind: String, value: String? = nil, defaultTitle: String = "Updating controller") -> String {
        DoorControllerSettingFormatting.title(for: kind, value: value, defaultTitle: defaultTitle)
    }

    public static func servoAnglesValue(_ angles: ServoAngles) -> String {
        DoorControllerSettingFormatting.servoAnglesValue(lockAngle: angles.lockAngle, unlockAngle: angles.unlockAngle)
    }

    public static func displayValue(for kind: String, rawValue: String?) -> String? {
        DoorControllerSettingFormatting.displayValue(for: kind, rawValue: rawValue)
    }

    public static func shortValue(_ value: String, maxLength: Int = 18) -> String? {
        DoorControllerSettingFormatting.shortValue(value, maxLength: maxLength)
    }
}
