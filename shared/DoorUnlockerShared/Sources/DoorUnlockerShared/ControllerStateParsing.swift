import Foundation

public struct DoorServoAngles: Equatable, Hashable, Sendable {
    public let lockAngle: Int
    public let unlockAngle: Int

    public init(lockAngle: Int, unlockAngle: Int) {
        self.lockAngle = lockAngle
        self.unlockAngle = unlockAngle
    }
}

public struct DoorLastUnlockRecord: Equatable, Hashable {
    public let unlockedAt: Date?
    public let deviceIdentifier: String?
    public let deviceName: String?

    public init(unlockedAt: Date?, deviceIdentifier: String?, deviceName: String?) {
        self.unlockedAt = unlockedAt
        self.deviceIdentifier = deviceIdentifier
        self.deviceName = deviceName
    }
}

public struct DoorParsedConnectedDevice: Identifiable, Equatable, Hashable {
    public let slot: Int
    public let name: String

    public init(slot: Int, name: String) {
        self.slot = slot
        self.name = name
    }

    public var id: Int { slot }

    public var displayName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Connected Device \(slot)"
            : name
    }
}

public struct DoorParsedConnectionsPayload: Equatable, Hashable {
    public let count: Int
    public let max: Int
    public let devices: [DoorParsedConnectedDevice]

    public init(count: Int, max: Int, devices: [DoorParsedConnectedDevice]) {
        self.count = count
        self.max = max
        self.devices = devices
    }
}

public enum DoorNameNormalizer {
    public static let maximumNameLength = 24

    public static func normalized(_ name: String, fallback: String, maximumLength: Int = maximumNameLength) -> String {
        let normalized = name
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{201B}", with: "'")
            .replacingOccurrences(of: "\u{2032}", with: "'")
            .replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
            .replacingOccurrences(of: "\u{201E}", with: "\"")
            .replacingOccurrences(of: "\u{2033}", with: "\"")
            .replacingOccurrences(of: "\u{2010}", with: "-")
            .replacingOccurrences(of: "\u{2011}", with: "-")
            .replacingOccurrences(of: "\u{2012}", with: "-")
            .replacingOccurrences(of: "\u{2013}", with: "-")
            .replacingOccurrences(of: "\u{2014}", with: "-")
            .replacingOccurrences(of: "\u{2026}", with: "...")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackName = normalized.isEmpty ? fallback : normalized
        let ascii = fallbackName.unicodeScalars.compactMap { scalar -> String? in
            scalar.isASCII && scalar.value >= 32 && scalar.value <= 126 ? String(scalar) : nil
        }

        return String(ascii.joined().prefix(maximumLength)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum DoorControllerStateParsing {
    public static func sessionIdentifier(from rawState: String) -> String? {
        guard let value = prefixedTrimmedValue(rawState, prefix: "session:"),
              value.count == 16,
              value.allSatisfy(\.isHexDigit) else { return nil }
        return value.lowercased()
    }

    public static func healthState(from rawState: String) -> String? {
        prefixedTrimmedValue(rawState, prefix: "health:")
    }

    public static func lockName(from rawState: String, fallback: String) -> String? {
        guard let rawName = prefixedValue(rawState, prefix: "lock_name:") else { return nil }

        let sanitizedName = DoorNameNormalizer.normalized(rawName, fallback: fallback)
        return sanitizedName.isEmpty ? nil : sanitizedName
    }

    public static func firmwareVersion(from rawState: String) -> String? {
        prefixedTrimmedValue(rawState, prefix: "firmware_version:")
    }

    public static func firmwareUpdateState(from rawState: String) -> String? {
        prefixedTrimmedValue(rawState, prefix: "firmware_update:")
    }

    public static func fastCommandNonce(from rawState: String) -> Data? {
        guard let hex = prefixedValue(rawState, prefix: "nonce:v3:") else { return nil }
        return dataFromHex(hex, expectedByteCount: 16)
    }

    public static func fastCommandRejectReason(from rawState: String) -> String? {
        guard let reason = prefixedTrimmedValue(rawState, prefix: "reject:v3:") else {
            return nil
        }
        return reason.isEmpty ? "rejected" : reason
    }

    public static func settingApplying(from rawState: String) -> (kind: String, value: String?)? {
        guard let payload = prefixedTrimmedValue(rawState, prefix: "setting_applying:") else {
            return nil
        }

        let parts = payload.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let kind = parts.first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let value = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : nil

        return (
            kind.isEmpty ? "settings" : kind,
            value?.isEmpty == true ? nil : value
        )
    }

    public static func servoAngles(from rawState: String) -> DoorServoAngles? {
        guard let payload = prefixedValue(rawState, prefix: "servo_angles:") else { return nil }

        let values = payload
            .split(separator: ",", maxSplits: 1)
            .compactMap { Int(String($0).trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard values.count == 2 else { return nil }

        return DoorServoAngles(lockAngle: values[0], unlockAngle: values[1])
    }

    public static func lastUnlockRecord(from rawState: String) -> DoorLastUnlockRecord? {
        guard let payload = prefixedValue(rawState, prefix: "last_unlock:") else { return nil }

        let parts = payload.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        let rawTimestamp = parts.first ?? ""
        guard let timestamp = TimeInterval(rawTimestamp), timestamp > 0 else {
            return DoorLastUnlockRecord(unlockedAt: nil, deviceIdentifier: nil, deviceName: nil)
        }

        let secondValue = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let thirdValue = parts.count > 2 ? parts[2].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let secondValueIsIdentifier = isTrustedDeviceIdentifier(secondValue)
        let identifier = secondValueIsIdentifier ? secondValue : nil
        let deviceName = secondValueIsIdentifier
            ? thirdValue
            : parts.dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespacesAndNewlines)

        return DoorLastUnlockRecord(
            unlockedAt: Date(timeIntervalSince1970: timestamp),
            deviceIdentifier: identifier?.isEmpty == true ? nil : identifier,
            deviceName: deviceName.isEmpty ? nil : deviceName
        )
    }

    public static func connectedDevices(from rawState: String) -> DoorParsedConnectionsPayload? {
        guard let payload = prefixedValue(rawState, prefix: "connections:") else { return nil }

        let parts = payload.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let countParts = (parts.first ?? "").split(separator: "/", maxSplits: 1).map(String.init)
        let count = Int(countParts.first ?? "") ?? 0
        let maxConnections = countParts.count > 1 ? (Int(countParts[1]) ?? max(count, 4)) : max(count, 4)
        let names = parts.count > 1
            ? parts[1].split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            : []
        let devices = names.enumerated().compactMap { index, rawName -> DoorParsedConnectedDevice? in
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            return DoorParsedConnectedDevice(slot: index + 1, name: name)
        }

        return DoorParsedConnectionsPayload(count: count, max: maxConnections, devices: devices)
    }

    public static func dataFromHex(_ hex: String, expectedByteCount: Int) -> Data? {
        guard hex.count == expectedByteCount * 2 else { return nil }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(expectedByteCount)
        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard nextIndex <= hex.endIndex,
                  let byte = UInt8(hex[index..<nextIndex], radix: 16) else {
                return nil
            }
            bytes.append(byte)
            index = nextIndex
        }

        return bytes.count == expectedByteCount ? Data(bytes) : nil
    }

    public static func isTrustedDeviceIdentifier(_ value: String) -> Bool {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedValue.count == 19 else { return false }

        for (index, character) in trimmedValue.enumerated() {
            if index == 4 || index == 9 || index == 14 {
                guard character == "-" else { return false }
            } else {
                guard character.isHexDigit else { return false }
            }
        }

        return true
    }

    public static func prefixedValue(_ rawState: String, prefix: String) -> String? {
        guard rawState.hasPrefix(prefix) else { return nil }
        return String(rawState.dropFirst(prefix.count))
    }

    private static func prefixedTrimmedValue(_ rawState: String, prefix: String) -> String? {
        guard let value = prefixedValue(rawState, prefix: prefix) else { return nil }
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }
}

public enum DoorControllerSettingFormatting {
    public static func title(for kind: String, value: String? = nil, defaultTitle: String) -> String {
        switch kind {
        case "lock_name":
            return value.map { "Lock name to \($0)" } ?? "Saving lock name"
        case "device_name":
            return value.map { "Device name to \($0)" } ?? "Saving device name"
        case "servo_angles":
            return value.map { "Angles to \($0)" } ?? "Updating angles"
        case "timeout":
            return value.map { "Auto-lock to \($0)" } ?? "Updating auto-lock"
        default:
            return defaultTitle
        }
    }

    public static func servoAnglesValue(lockAngle: Int, unlockAngle: Int) -> String {
        "\(lockAngle)° / \(unlockAngle)°"
    }

    public static func displayValue(for kind: String, rawValue: String?) -> String? {
        guard let rawValue else { return nil }

        switch kind {
        case "lock_name", "device_name":
            return shortValue(rawValue)
        case "servo_angles":
            let parts = rawValue.split(separator: ",", maxSplits: 1).map(String.init)
            guard parts.count == 2,
                  let lockAngle = Int(parts[0].trimmingCharacters(in: .whitespacesAndNewlines)),
                  let unlockAngle = Int(parts[1].trimmingCharacters(in: .whitespacesAndNewlines)) else {
                return shortValue(rawValue)
            }
            return servoAnglesValue(lockAngle: lockAngle, unlockAngle: unlockAngle)
        case "timeout":
            let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedValue.isEmpty else { return nil }
            return trimmedValue.hasSuffix("s") ? trimmedValue : "\(trimmedValue)s"
        default:
            return shortValue(rawValue)
        }
    }

    public static func shortValue(_ value: String, maxLength: Int = 18) -> String? {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else { return nil }
        guard trimmedValue.count > maxLength else { return trimmedValue }

        let endIndex = trimmedValue.index(trimmedValue.startIndex, offsetBy: maxLength)
        return "\(trimmedValue[..<endIndex])..."
    }
}
