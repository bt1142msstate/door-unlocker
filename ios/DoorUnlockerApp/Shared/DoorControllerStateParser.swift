import Foundation
import DoorUnlockerShared

typealias ServoAngles = DoorServoAngles
typealias LastUnlockRecord = DoorLastUnlockRecord
typealias ConnectedControllerDevice = DoorParsedConnectedDevice
typealias ControllerConnectionsPayload = DoorParsedConnectionsPayload

enum DoorControllerStateParser {
    static func lockName(from rawState: String) -> String? {
        DoorControllerStateParsing.lockName(from: rawState, fallback: DoorStatusStore.defaultLockName)
    }

    static func firmwareVersion(from rawState: String) -> String? {
        DoorControllerStateParsing.firmwareVersion(from: rawState)
    }

    static func firmwareUpdateState(from rawState: String) -> String? {
        DoorControllerStateParsing.firmwareUpdateState(from: rawState)
    }

    static func firmwareUpdateAnnouncement(
        from rawState: String
    ) -> (state: String, updaterName: String?)? {
        DoorControllerStateParsing.firmwareUpdateAnnouncement(from: rawState)
    }

    static func fastCommandNonce(from rawState: String) -> Data? {
        DoorControllerStateParsing.fastCommandNonce(from: rawState)
    }

    static func fastCommandRejectReason(from rawState: String) -> String? {
        DoorControllerStateParsing.fastCommandRejectReason(from: rawState)
    }

    static func settingApplying(from rawState: String) -> (kind: String, value: String?)? {
        DoorControllerStateParsing.settingApplying(from: rawState)
    }

    static func servoAngles(from rawState: String) -> ServoAngles? {
        DoorControllerStateParsing.servoAngles(from: rawState)
    }

    static func lastUnlockRecord(from rawState: String) -> LastUnlockRecord? {
        DoorControllerStateParsing.lastUnlockRecord(from: rawState)
    }

    static func connectedDevices(from rawState: String) -> ControllerConnectionsPayload? {
        DoorControllerStateParsing.connectedDevices(from: rawState)
    }
}

enum DoorControllerSettingFormatter {
    static func title(for kind: String, value: String? = nil) -> String {
        DoorControllerSettingFormatting.title(for: kind, value: value, defaultTitle: "Applying setting")
    }

    static func servoAnglesValue(_ angles: ServoAngles) -> String {
        DoorControllerSettingFormatting.servoAnglesValue(
            lockAngle: angles.lockAngle,
            unlockAngle: angles.unlockAngle
        )
    }

    static func displayValue(for kind: String, rawValue: String?) -> String? {
        DoorControllerSettingFormatting.displayValue(for: kind, rawValue: rawValue)
    }

    static func shortValue(_ value: String, maxLength: Int = 18) -> String? {
        DoorControllerSettingFormatting.shortValue(value, maxLength: maxLength)
    }
}
