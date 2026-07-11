import Foundation

public enum DoorSerialParser {
    public static func isValidControllerStatusResponse(_ lines: [String]) -> Bool {
        guard lines.contains("APP_STATUS_BEGIN"),
              lines.contains("APP_STATUS_END") else { return false }

        let fields = blockLines(lines, begin: "APP_STATUS_BEGIN", end: "APP_STATUS_END")
            .compactMap(keyValue)
            .reduce(into: [String: String]()) { values, field in
                values[field.0] = field.1
            }
        return fields["protocol"] == "1"
            && (fields["model"]?.hasPrefix("DoorUnlocker-") ?? false)
            && !(fields["boot_session"]?.isEmpty ?? true)
            && ["ok", "fault"].contains(fields["storage_health"])
    }

    public static func parseStatus(from lines: [String]) -> ControllerStatus {
        var status = ControllerStatus()

        for line in blockLines(lines, begin: "APP_STATUS_BEGIN", end: "APP_STATUS_END") {
            guard let (key, value) = keyValue(line) else { continue }

            switch key {
            case "model":
                status.modelName = value
            case "firmware_version":
                status.firmwareVersion = value.isEmpty ? status.firmwareVersion : value
            case "lock_name":
                status.lockName = value
            case "protocol":
                status.protocolVersion = value
            case "boot_session":
                status.bootSessionIdentifier = value.isEmpty ? nil : value
            case "storage_health":
                status.storageHealth = value
            case "pairing_mode":
                status.pairingMode = value
            case "paired_count":
                status.pairedCount = Int(value) ?? status.pairedCount
            case "max_pairs":
                status.maxPairs = Int(value) ?? status.maxPairs
            case "ble_connected_count":
                status.connectedCount = Int(value) ?? status.connectedCount
            case "ble_max_connections":
                status.maxConnections = Int(value) ?? status.maxConnections
            case "connected_device":
                let fields = keyValueFields(value)
                let slot = Int(fields["index"] ?? "") ?? status.connectedDevices.count + 1
                status.connectedDevices.append(
                    ConnectedControllerDevice(
                        slot: slot,
                        handle: fields["handle"] ?? "",
                        name: fields["name"] ?? "",
                        isTrustedName: fields["trusted"] == "yes"
                    )
                )
            case "pending":
                status.hasPendingRequest = value == "yes"
            case "pending_name":
                status.pendingName = value.isEmpty ? nil : value
            case "ble_state":
                let payload = ControllerStatePayload.parse(value)
                status.bleState = payload.state
                status.autoLockRemainingSeconds = payload.remainingSeconds
            case "setting_applying":
                let applying = settingApplying(from: value)
                status.settingApplyingKind = applying.kind
                status.settingApplyingValue = applying.value
            case "unlocked":
                status.isUnlocked = value == "yes"
            case "auto_lock_seconds":
                status.autoLockSeconds = Int(value) ?? status.autoLockSeconds
            case "auto_lock_remaining_seconds":
                status.autoLockRemainingSeconds = Int(value)
            case "lock_angle":
                status.lockAngle = Int(value) ?? status.lockAngle
            case "unlock_angle":
                status.unlockAngle = Int(value) ?? status.unlockAngle
            case "servo_min_angle":
                status.servoMinAngle = Int(value) ?? status.servoMinAngle
            case "servo_max_angle":
                status.servoMaxAngle = Int(value) ?? status.servoMaxAngle
            case "servo_min_angle_gap":
                status.servoMinAngleGap = Int(value) ?? status.servoMinAngleGap
            case "last_unlock_epoch":
                if let timestamp = TimeInterval(value), timestamp > 0 {
                    status.lastUnlockAt = Date(timeIntervalSince1970: timestamp)
                } else {
                    status.lastUnlockAt = nil
                }
            case "last_unlock_device_id":
                status.lastUnlockDeviceIdentifier = value.isEmpty ? nil : value
            case "last_unlock_device":
                status.lastUnlockDeviceName = value.isEmpty ? nil : value
            default:
                continue
            }
        }

        if !status.isUnlocked {
            status.autoLockRemainingSeconds = nil
            status.autoLockDeadline = nil
        } else if let remainingSeconds = status.autoLockRemainingSeconds {
            status.autoLockDeadline = Date().addingTimeInterval(TimeInterval(max(0, remainingSeconds)))
        }

        return status
    }

    public static func parsePairs(from lines: [String]) -> [PairedDevice] {
        blockLines(lines, begin: "APP_PAIRS_BEGIN", end: "APP_PAIRS_END").compactMap { line in
            guard line.hasPrefix("pair ") else { return nil }
            let values = keyValueFields(line)
            guard let indexText = values["index"], let slot = Int(indexText) else { return nil }

            return PairedDevice(
                slot: slot,
                fingerprint: values["fingerprint"] ?? "unknown",
                counter: values["counter"] ?? "0",
                name: values["name"]
            )
        }
    }

    public static func responseSummary(from lines: [String]) -> String? {
        lines.last { line in
            line.hasPrefix("APP_OK") || line.hasPrefix("APP_ERROR")
        }
    }

    private static func settingApplying(from value: String) -> (kind: String?, value: String?) {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else { return (nil, nil) }

        let parts = trimmedValue.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let kind = parts.first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let settingValue = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : nil

        return (kind?.isEmpty == true ? nil : kind, settingValue?.isEmpty == true ? nil : settingValue)
    }

    private static func blockLines(_ lines: [String], begin: String, end: String) -> [String] {
        var isInsideBlock = false
        var result: [String] = []

        for line in lines {
            if line == begin {
                isInsideBlock = true
                continue
            }

            if line == end {
                break
            }

            if isInsideBlock {
                result.append(line)
            }
        }

        return result
    }

    private static func keyValue(_ line: String) -> (String, String)? {
        guard let separator = line.firstIndex(of: "=") else { return nil }
        let key = String(line[..<separator])
        let value = String(line[line.index(after: separator)...])
        return (key, value)
    }

    private static func keyValueFields(_ line: String) -> [String: String] {
        var fieldText = line
        var parsedName: String?
        if let nameRange = line.range(of: " name=") {
            parsedName = String(line[nameRange.upperBound...])
            fieldText = String(line[..<nameRange.lowerBound])
        }

        var fields = fieldText.split(separator: " ").reduce(into: [String: String]()) { fields, part in
            let text = String(part)
            guard let separator = text.firstIndex(of: "=") else { return }
            let key = String(text[..<separator])
            let value = String(text[text.index(after: separator)...])
            fields[key] = value
        }
        if let parsedName, !parsedName.isEmpty {
            fields["name"] = parsedName
        }
        return fields
    }
}
