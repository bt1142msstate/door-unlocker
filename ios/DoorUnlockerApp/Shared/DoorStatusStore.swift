import Foundation
import ActivityKit

struct DoorUnlockerActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        let state: String
        let autoLockStartedAt: Date?
        let autoLockDeadline: Date
        let lockAnimationStartedAt: Date?
        let lockAnimationPhase: Int?
        let activityKind: String
        let firmwareStatus: String?
        let firmwareProgress: Int?
        let firmwareVersion: String?

        init(
            state: String,
            autoLockStartedAt: Date? = nil,
            autoLockDeadline: Date,
            lockAnimationStartedAt: Date? = nil,
            lockAnimationPhase: Int? = nil,
            activityKind: String = "door",
            firmwareStatus: String? = nil,
            firmwareProgress: Int? = nil,
            firmwareVersion: String? = nil
        ) {
            self.state = state
            self.autoLockDeadline = autoLockDeadline
            self.autoLockStartedAt = autoLockStartedAt
            self.lockAnimationStartedAt = lockAnimationStartedAt
            self.lockAnimationPhase = lockAnimationPhase
            self.activityKind = activityKind
            self.firmwareStatus = firmwareStatus
            self.firmwareProgress = firmwareProgress
            self.firmwareVersion = firmwareVersion
        }

        var isFirmwareUpdate: Bool {
            activityKind == "firmware"
        }

        var isUnlocked: Bool {
            state == "unlocked" || state == "unlocking"
        }

        var isLocked: Bool {
            state == "locked" || state == "locking"
        }
    }

    let title: String
}

enum DoorStatusStore {
    static let appGroupIdentifier = "group.io.github.bt1142msstate.DoorUnlocker"
    static let defaultLockName = "My Lock"

    private static let lockNameKey = "DoorUnlockerLockName"
    private static let stateKey = "DoorUnlockerLastState"
    private static let updatedAtKey = "DoorUnlockerLastStateUpdatedAt"
    private static let autoLockStartedAtKey = "DoorUnlockerAutoLockStartedAt"
    private static let autoLockDeadlineKey = "DoorUnlockerAutoLockDeadline"
    private static let maximumLockNameLength = 24

    static var sharedDefaults: UserDefaults {
        UserDefaults(suiteName: appGroupIdentifier) ?? .standard
    }

    static func saveLockName(_ name: String) {
        let sanitizedName = sanitizedLockName(name)
        guard !sanitizedName.isEmpty else { return }

        sharedDefaults.set(sanitizedName, forKey: lockNameKey)
        sharedDefaults.synchronize()
    }

    static func loadLockName() -> String {
        guard let storedName = sharedDefaults.string(forKey: lockNameKey) else {
            return defaultLockName
        }

        let sanitizedName = sanitizedLockName(storedName)
        return sanitizedName.isEmpty ? defaultLockName : sanitizedName
    }

    static func sanitizedLockName(_ name: String) -> String {
        let normalizedName = normalizedNameSource(name)
        let fallback = normalizedName.isEmpty ? defaultLockName : normalizedName
        let ascii = fallback.unicodeScalars.compactMap { scalar -> String? in
            scalar.isASCII && scalar.value >= 32 && scalar.value <= 126 ? String(scalar) : nil
        }
        return String(ascii.joined().prefix(maximumLockNameLength)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedNameSource(_ name: String) -> String {
        name
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
    }

    static func save(state: String, updatedAt: Date = .now, autoLockStartedAt: Date? = nil, autoLockDeadline: Date? = nil) {
        sharedDefaults.set(state, forKey: stateKey)
        sharedDefaults.set(updatedAt.timeIntervalSince1970, forKey: updatedAtKey)

        if let autoLockDeadline, state == "unlocked" || state == "unlocking" {
            if let autoLockStartedAt {
                sharedDefaults.set(autoLockStartedAt.timeIntervalSince1970, forKey: autoLockStartedAtKey)
            } else {
                sharedDefaults.removeObject(forKey: autoLockStartedAtKey)
            }
            sharedDefaults.set(autoLockDeadline.timeIntervalSince1970, forKey: autoLockDeadlineKey)
        } else {
            sharedDefaults.removeObject(forKey: autoLockStartedAtKey)
            sharedDefaults.removeObject(forKey: autoLockDeadlineKey)
        }

        sharedDefaults.synchronize()
    }

    static func load() -> Snapshot {
        let state = sharedDefaults.string(forKey: stateKey) ?? "unknown"
        let timestamp = sharedDefaults.double(forKey: updatedAtKey)
        let updatedAt = timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : nil

        let deadlineTimestamp = sharedDefaults.double(forKey: autoLockDeadlineKey)
        let autoLockDeadline = deadlineTimestamp > 0 ? Date(timeIntervalSince1970: deadlineTimestamp) : nil
        let startedAtTimestamp = sharedDefaults.double(forKey: autoLockStartedAtKey)
        let autoLockStartedAt = startedAtTimestamp > 0 ? Date(timeIntervalSince1970: startedAtTimestamp) : nil
        if let autoLockDeadline, autoLockDeadline <= .now, state == "unlocked" || state == "unlocking" {
            return Snapshot(state: "locked", updatedAt: autoLockDeadline, autoLockStartedAt: nil, autoLockDeadline: nil)
        }

        return Snapshot(state: state, updatedAt: updatedAt, autoLockStartedAt: autoLockStartedAt, autoLockDeadline: autoLockDeadline)
    }

    struct Snapshot {
        let state: String
        let updatedAt: Date?
        let autoLockStartedAt: Date?
        let autoLockDeadline: Date?

        var title: String {
            switch state {
            case "locked":
                return "Locked"
            case "unlocked":
                return "Unlocked"
            case "locking":
                return "Locking"
            case "unlocking":
                return "Unlocking"
            default:
                return "Unknown"
            }
        }

        var isUnlocked: Bool {
            state == "unlocked" || state == "unlocking"
        }

        var nextActionTitle: String {
            isUnlocked ? "Lock" : "Unlock"
        }

        var nextActionName: String {
            isUnlocked ? "lock" : "unlock"
        }

        var nextActionSymbolName: String {
            isUnlocked ? "lock.fill" : "lock.open.fill"
        }

        var symbolName: String {
            isUnlocked ? "lock.open.fill" : "lock.fill"
        }
    }
}
