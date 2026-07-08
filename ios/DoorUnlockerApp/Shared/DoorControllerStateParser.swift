import Foundation
import DoorUnlockerShared

typealias ServoAngles = DoorServoAngles
typealias LastUnlockRecord = DoorLastUnlockRecord

struct ConnectedControllerDevice: Identifiable, Equatable {
    let slot: Int
    let name: String

    var id: Int { slot }

    var displayName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Connected Device \(slot)" : name
    }
}

struct ControllerConnectionsPayload {
    let count: Int
    let max: Int
    let devices: [ConnectedControllerDevice]
}

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
        guard let payload = DoorControllerStateParsing.connectedDevices(from: rawState) else { return nil }
        let devices = payload.devices.map { device in
            ConnectedControllerDevice(slot: device.slot, name: device.name)
        }
        return ControllerConnectionsPayload(count: payload.count, max: payload.max, devices: devices)
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
