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
    public static let defaultLockAngle = 20
    public static let defaultUnlockAngle = 95
    public static let defaultServoMinAngle = 10
    public static let defaultServoMaxAngle = 170
    public static let defaultServoMinAngleGap = 10

    public var modelName = "DoorUnlocker-XIAO-v4"
    public var firmwareVersion = "Unknown"
    public var lockName = "My Lock"
    public var protocolVersion = "unknown"
    public var pairingMode = "unknown"
    public var pairedCount = 0
    public var maxPairs = 0
    public var connectedCount = 0
    public var maxConnections = 4
    public var connectedDevices: [ConnectedControllerDevice] = []
    public var hasPendingRequest = false
    public var pendingName: String?
    public var bleState = "unknown"
    public var settingApplyingKind: String?
    public var settingApplyingValue: String?
    public var isUnlocked = false
    public var autoLockSeconds = 30
    public var autoLockRemainingSeconds: Int?
    public var autoLockDeadline: Date?
    public var lockAngle = ControllerStatus.defaultLockAngle
    public var unlockAngle = ControllerStatus.defaultUnlockAngle
    public var servoMinAngle = ControllerStatus.defaultServoMinAngle
    public var servoMaxAngle = ControllerStatus.defaultServoMaxAngle
    public var servoMinAngleGap = ControllerStatus.defaultServoMinAngleGap
    public var lastUnlockAt: Date?
    public var lastUnlockDeviceIdentifier: String?
    public var lastUnlockDeviceName: String?

    public init(
        modelName: String = "DoorUnlocker-XIAO-v4",
        firmwareVersion: String = "Unknown",
        lockName: String = "My Lock",
        protocolVersion: String = "unknown",
        pairingMode: String = "unknown",
        pairedCount: Int = 0,
        maxPairs: Int = 0,
        connectedCount: Int = 0,
        maxConnections: Int = 4,
        connectedDevices: [ConnectedControllerDevice] = [],
        hasPendingRequest: Bool = false,
        pendingName: String? = nil,
        bleState: String = "unknown",
        settingApplyingKind: String? = nil,
        settingApplyingValue: String? = nil,
        isUnlocked: Bool = false,
        autoLockSeconds: Int = 30,
        autoLockRemainingSeconds: Int? = nil,
        autoLockDeadline: Date? = nil,
        lockAngle: Int = ControllerStatus.defaultLockAngle,
        unlockAngle: Int = ControllerStatus.defaultUnlockAngle,
        servoMinAngle: Int = ControllerStatus.defaultServoMinAngle,
        servoMaxAngle: Int = ControllerStatus.defaultServoMaxAngle,
        servoMinAngleGap: Int = ControllerStatus.defaultServoMinAngleGap,
        lastUnlockAt: Date? = nil,
        lastUnlockDeviceIdentifier: String? = nil,
        lastUnlockDeviceName: String? = nil
    ) {
        self.modelName = modelName
        self.firmwareVersion = firmwareVersion
        self.lockName = lockName
        self.protocolVersion = protocolVersion
        self.pairingMode = pairingMode
        self.pairedCount = pairedCount
        self.maxPairs = maxPairs
        self.connectedCount = connectedCount
        self.maxConnections = maxConnections
        self.connectedDevices = connectedDevices
        self.hasPendingRequest = hasPendingRequest
        self.pendingName = pendingName
        self.bleState = bleState
        self.settingApplyingKind = settingApplyingKind
        self.settingApplyingValue = settingApplyingValue
        self.isUnlocked = isUnlocked
        self.autoLockSeconds = autoLockSeconds
        self.autoLockRemainingSeconds = autoLockRemainingSeconds
        self.autoLockDeadline = autoLockDeadline
        self.lockAngle = lockAngle
        self.unlockAngle = unlockAngle
        self.servoMinAngle = servoMinAngle
        self.servoMaxAngle = servoMaxAngle
        self.servoMinAngleGap = servoMinAngleGap
        self.lastUnlockAt = lastUnlockAt
        self.lastUnlockDeviceIdentifier = lastUnlockDeviceIdentifier
        self.lastUnlockDeviceName = lastUnlockDeviceName
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

    public var connectionCapacityTitle: String {
        "\(connectedCount)/\(max(maxConnections, 4)) connected"
    }

    public var unidentifiedConnectedDeviceCount: Int {
        max(0, connectedCount - connectedDevices.count)
    }

    public var autoLockCountdownText: String? {
        guard isUnlocked, let autoLockRemainingSeconds else { return nil }
        guard autoLockRemainingSeconds > 0 else { return "Auto-locking now" }
        return "Auto-locks in \(autoLockRemainingSeconds)s"
    }

    public var servoAngleRange: ClosedRange<Int> {
        let lower = min(servoMinAngle, servoMaxAngle)
        let upper = max(servoMinAngle, servoMaxAngle)
        return lower ... upper
    }

    public var servoAngles: ServoAngles {
        ServoAngles(lockAngle: lockAngle, unlockAngle: unlockAngle)
    }

    public var lastUnlockTitle: String {
        guard let lastUnlockAt else { return "No unlock recorded" }
        return lastUnlockAt.formatted(date: .abbreviated, time: .shortened)
    }

    public var lastUnlockRelativeTitle: String? {
        guard let lastUnlockAt else { return nil }
        return lastUnlockAt.formatted(.relative(presentation: .named))
    }

    public var lastUnlockDeviceTitle: String? {
        guard lastUnlockAt != nil,
              let lastUnlockDeviceName,
              !lastUnlockDeviceName.isEmpty else {
            return nil
        }
        return lastUnlockDeviceName
    }

    public func includingLocalConnection(_ device: ConnectedControllerDevice, minimumMaxConnections: Int = 4) -> ControllerStatus {
        var nextStatus = removingConnection(handle: device.handle)
        nextStatus.connectedDevices.insert(device, at: 0)
        nextStatus.connectedCount = max(nextStatus.connectedCount + 1, nextStatus.connectedDevices.count)
        nextStatus.maxConnections = max(nextStatus.maxConnections, nextStatus.connectedCount, minimumMaxConnections)
        return nextStatus
    }

    public func removingConnection(handle: String) -> ControllerStatus {
        var nextStatus = self
        let previousDeviceCount = nextStatus.connectedDevices.count
        nextStatus.connectedDevices.removeAll { $0.handle == handle }
        let removedDeviceCount = previousDeviceCount - nextStatus.connectedDevices.count
        if removedDeviceCount > 0 {
            nextStatus.connectedCount = max(nextStatus.connectedDevices.count, max(0, nextStatus.connectedCount - removedDeviceCount))
        }
        return nextStatus
    }
}

public struct ConnectedControllerDevice: Identifiable, Equatable, Hashable {
    public let slot: Int
    public let handle: String
    public let name: String
    public let isTrustedName: Bool

    public init(slot: Int, handle: String, name: String, isTrustedName: Bool) {
        self.slot = slot
        self.handle = handle
        self.name = name
        self.isTrustedName = isTrustedName
    }

    public var id: String {
        handle.isEmpty ? "slot-\(slot)" : handle
    }

    public var displayName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Connected Device \(slot)" : name
    }

    public var trustTitle: String {
        isTrustedName ? "Trusted" : "Connected"
    }
}

public struct ServoAngles: Equatable, Hashable {
    public var lockAngle: Int
    public var unlockAngle: Int

    public init(lockAngle: Int, unlockAngle: Int) {
        self.lockAngle = lockAngle
        self.unlockAngle = unlockAngle
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
