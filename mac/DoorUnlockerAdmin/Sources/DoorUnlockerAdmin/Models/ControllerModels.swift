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
    var pendingName: String?
    var bleState = "unknown"
    var isUnlocked = false
    var autoLockSeconds = 30
    var autoLockRemainingSeconds: Int?

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

    var autoLockCountdownText: String? {
        guard isUnlocked, let autoLockRemainingSeconds else { return nil }
        guard autoLockRemainingSeconds > 0 else { return "Auto-locking now" }
        return "Auto-locks in \(autoLockRemainingSeconds)s"
    }
}

struct ControllerStatePayload {
    let state: String
    let remainingSeconds: Int?

    static func parse(_ rawState: String) -> ControllerStatePayload {
        let trimmedState = rawState.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmedState.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts[0] == "unlocked",
              let remainingSeconds = Int(parts[1]) else {
            return ControllerStatePayload(state: trimmedState, remainingSeconds: nil)
        }

        return ControllerStatePayload(state: "unlocked", remainingSeconds: max(0, remainingSeconds))
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
