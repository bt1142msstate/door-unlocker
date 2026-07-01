import Foundation

public struct SerialPortCandidate: Identifiable, Hashable {
    public let path: String

    public init(path: String) {
        self.path = path
    }

    public var id: String { path }

    public var displayName: String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    public var isLikelyXiao: Bool {
        displayName.localizedCaseInsensitiveContains("usbmodem")
    }
}

public struct ControllerStatus: Equatable {
    public var modelName = "DoorUnlocker-XIAO-v2"
    public var protocolVersion = "unknown"
    public var pairingMode = "unknown"
    public var pairedCount = 0
    public var maxPairs = 0
    public var hasPendingRequest = false
    public var pendingName: String?
    public var bleState = "unknown"
    public var isUnlocked = false
    public var autoLockSeconds = 30
    public var autoLockRemainingSeconds: Int?
    public var autoLockDeadline: Date?

    public init(
        modelName: String = "DoorUnlocker-XIAO-v2",
        protocolVersion: String = "unknown",
        pairingMode: String = "unknown",
        pairedCount: Int = 0,
        maxPairs: Int = 0,
        hasPendingRequest: Bool = false,
        pendingName: String? = nil,
        bleState: String = "unknown",
        isUnlocked: Bool = false,
        autoLockSeconds: Int = 30,
        autoLockRemainingSeconds: Int? = nil,
        autoLockDeadline: Date? = nil
    ) {
        self.modelName = modelName
        self.protocolVersion = protocolVersion
        self.pairingMode = pairingMode
        self.pairedCount = pairedCount
        self.maxPairs = maxPairs
        self.hasPendingRequest = hasPendingRequest
        self.pendingName = pendingName
        self.bleState = bleState
        self.isUnlocked = isUnlocked
        self.autoLockSeconds = autoLockSeconds
        self.autoLockRemainingSeconds = autoLockRemainingSeconds
        self.autoLockDeadline = autoLockDeadline
    }

    public static let disconnected = ControllerStatus()

    public var modelTitle: String {
        modelName.isEmpty ? "Unknown model" : modelName
    }

    public var stateTitle: String {
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

    public var pairingTitle: String {
        pairingMode == "enabled" ? "Enabled" : "Locked"
    }

    public var autoLockCountdownText: String? {
        guard isUnlocked, let autoLockRemainingSeconds else { return nil }
        guard autoLockRemainingSeconds > 0 else { return "Auto-locking now" }
        return "Auto-locks in \(autoLockRemainingSeconds)s"
    }
}

public struct ControllerStatePayload {
    public let state: String
    public let remainingSeconds: Int?

    public static func parse(_ rawState: String) -> ControllerStatePayload {
        let trimmedState = rawState.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmedState.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              let remainingSeconds = Int(parts[1]) else {
            return ControllerStatePayload(state: trimmedState, remainingSeconds: nil)
        }

        if parts[0] == "unlocked" {
            return ControllerStatePayload(state: "unlocked", remainingSeconds: max(0, remainingSeconds))
        }

        if parts[0] == "timeout_set" {
            return ControllerStatePayload(state: "timeout_set", remainingSeconds: max(0, remainingSeconds))
        }

        return ControllerStatePayload(state: trimmedState, remainingSeconds: nil)
    }
}

public struct PairedDevice: Identifiable, Hashable {
    public let slot: Int
    public let fingerprint: String
    public let counter: String
    public let name: String?

    public init(slot: Int, fingerprint: String, counter: String, name: String?) {
        self.slot = slot
        self.fingerprint = fingerprint
        self.counter = counter
        self.name = name
    }

    public var id: String {
        fingerprint == "unknown" ? "slot-\(slot)" : fingerprint
    }

    public var displayName: String {
        guard let name, !name.isEmpty else {
            return "Trusted device"
        }
        return name
    }

    public var kindTitle: String {
        guard let savedName = name, !savedName.isEmpty else {
            return "No display name saved"
        }

        if savedName.localizedCaseInsensitiveContains("mac") {
            return "Trusted Mac"
        }
        if savedName.localizedCaseInsensitiveContains("iphone") {
            return "Trusted iPhone"
        }
        return "Trusted device"
    }
}
