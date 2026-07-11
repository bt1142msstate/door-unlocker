import Foundation

public enum DoorControllerStorageHealth: String, Equatable, Sendable {
    case unknown
    case ok
    case storageFault = "storage_fault"

    public init(controllerValue: String) {
        self = Self(rawValue: controllerValue) ?? .unknown
    }
}

public struct DoorControllerFreshnessTracker: Equatable, Sendable {
    public private(set) var generation: UInt64 = 0
    public private(set) var bootSessionIdentifier: String?
    public private(set) var storageHealth: DoorControllerStorageHealth = .unknown
    public private(set) var hasCurrentStateSnapshot = false
    public private(set) var hasCurrentConnectionRoster = false

    public init() {}

    public mutating func invalidateTransport() {
        generation &+= 1
        bootSessionIdentifier = nil
        storageHealth = .unknown
        hasCurrentStateSnapshot = false
        hasCurrentConnectionRoster = false
    }

    @discardableResult
    public mutating func receiveBootSession(_ identifier: String) -> Bool {
        let normalized = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        guard normalized != bootSessionIdentifier else { return false }

        generation &+= 1
        bootSessionIdentifier = normalized
        storageHealth = .unknown
        hasCurrentStateSnapshot = false
        hasCurrentConnectionRoster = false
        return true
    }

    @discardableResult
    public mutating func receiveStorageHealth(_ controllerValue: String) -> Bool {
        guard bootSessionIdentifier != nil else { return false }
        storageHealth = DoorControllerStorageHealth(controllerValue: controllerValue)
        return true
    }

    @discardableResult
    public mutating func receiveStateSnapshot() -> Bool {
        guard bootSessionIdentifier != nil else { return false }
        hasCurrentStateSnapshot = true
        return true
    }

    @discardableResult
    public mutating func receiveConnectionRoster() -> Bool {
        guard bootSessionIdentifier != nil else { return false }
        hasCurrentConnectionRoster = true
        return true
    }

    public var hasAuthoritativeState: Bool {
        bootSessionIdentifier != nil && storageHealth == .ok && hasCurrentStateSnapshot
    }

    public func hasCompleteMetadataSnapshot(hasCurrentFirmwareVersion: Bool) -> Bool {
        hasAuthoritativeState && hasCurrentConnectionRoster && hasCurrentFirmwareVersion
    }
}
