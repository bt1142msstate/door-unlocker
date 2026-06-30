import Foundation

struct SerialPortCandidate: Identifiable, Hashable {
    let path: String

    var id: String { path }

    var displayName: String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    var isLikelyXiao: Bool {
        displayName.localizedCaseInsensitiveContains("usbmodem")
    }
}

struct ControllerStatus: Equatable {
    var protocolVersion = "unknown"
    var pairingMode = "unknown"
    var pairedCount = 0
    var maxPairs = 0
    var hasPendingRequest = false
    var pendingFingerprint: String?
    var pendingName: String?
    var bleState = "unknown"
    var isUnlocked = false
    var autoLockSeconds = 30

    static let disconnected = ControllerStatus()

    var stateTitle: String {
        switch bleState {
        case "locked":
            return "Locked"
        case "unlocked":
            return "Unlocked"
        case "locking":
            return "Locking"
        case "unlocking":
            return "Unlocking"
        case "pairing_enabled":
            return "Pairing Enabled"
        case "pairing_pending":
            return "Pairing Pending"
        case "pairing_locked":
            return "Pairing Locked"
        case "paired":
            return "Paired"
        default:
            return "Unknown"
        }
    }

    var pairingTitle: String {
        pairingMode == "enabled" ? "Enabled" : "Locked"
    }
}

struct PairedDevice: Identifiable, Hashable {
    let slot: Int
    let fingerprint: String
    let counter: String
    let name: String?

    var id: String {
        fingerprint == "unknown" ? "slot-\(slot)" : fingerprint
    }

    var displayName: String {
        guard let name, !name.isEmpty else {
            return "Device \(slot)"
        }
        return name
    }
}
