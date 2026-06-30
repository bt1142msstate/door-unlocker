import Foundation

enum DoorStatusStore {
    static let appGroupIdentifier = "group.io.github.bt1142msstate.DoorUnlocker"

    private static let stateKey = "DoorUnlockerLastState"
    private static let updatedAtKey = "DoorUnlockerLastStateUpdatedAt"
    private static let autoLockDeadlineKey = "DoorUnlockerAutoLockDeadline"

    static var sharedDefaults: UserDefaults {
        UserDefaults(suiteName: appGroupIdentifier) ?? .standard
    }

    static func save(state: String, updatedAt: Date = .now, autoLockDeadline: Date? = nil) {
        sharedDefaults.set(state, forKey: stateKey)
        sharedDefaults.set(updatedAt.timeIntervalSince1970, forKey: updatedAtKey)

        if let autoLockDeadline, state == "unlocked" || state == "unlocking" {
            sharedDefaults.set(autoLockDeadline.timeIntervalSince1970, forKey: autoLockDeadlineKey)
        } else {
            sharedDefaults.removeObject(forKey: autoLockDeadlineKey)
        }
    }

    static func load() -> Snapshot {
        let state = sharedDefaults.string(forKey: stateKey) ?? "unknown"
        let timestamp = sharedDefaults.double(forKey: updatedAtKey)
        let updatedAt = timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : nil

        let deadlineTimestamp = sharedDefaults.double(forKey: autoLockDeadlineKey)
        let autoLockDeadline = deadlineTimestamp > 0 ? Date(timeIntervalSince1970: deadlineTimestamp) : nil
        if let autoLockDeadline, autoLockDeadline <= .now, state == "unlocked" || state == "unlocking" {
            return Snapshot(state: "locked", updatedAt: autoLockDeadline, autoLockDeadline: nil)
        }

        return Snapshot(state: state, updatedAt: updatedAt, autoLockDeadline: autoLockDeadline)
    }

    struct Snapshot {
        let state: String
        let updatedAt: Date?
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
