import Foundation

enum DoorStatusStore {
    static let appGroupIdentifier = "group.io.github.bt1142msstate.DoorUnlocker"

    private static let stateKey = "DoorUnlockerLastState"
    private static let updatedAtKey = "DoorUnlockerLastStateUpdatedAt"

    static var sharedDefaults: UserDefaults {
        UserDefaults(suiteName: appGroupIdentifier) ?? .standard
    }

    static func save(state: String, updatedAt: Date = .now) {
        sharedDefaults.set(state, forKey: stateKey)
        sharedDefaults.set(updatedAt.timeIntervalSince1970, forKey: updatedAtKey)
    }

    static func load() -> Snapshot {
        let state = sharedDefaults.string(forKey: stateKey) ?? "unknown"
        let timestamp = sharedDefaults.double(forKey: updatedAtKey)
        let updatedAt = timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : nil
        return Snapshot(state: state, updatedAt: updatedAt)
    }

    struct Snapshot {
        let state: String
        let updatedAt: Date?

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
