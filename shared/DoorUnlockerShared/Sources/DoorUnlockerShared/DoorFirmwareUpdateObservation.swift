import Foundation

public struct DoorFirmwareUpdateObservation: Equatable, Sendable {
    public static let defaultTimeout: TimeInterval = 180
    public static let defaultEstimatedDuration: TimeInterval = 30

    public private(set) var announcedAt: Date?
    public private(set) var updatedAt: Date?
    public private(set) var updaterName: String?
    public private(set) var estimatedDuration: TimeInterval

    public init(
        announcedAt: Date? = nil,
        updatedAt: Date? = nil,
        updaterName: String? = nil,
        estimatedDuration: TimeInterval = Self.defaultEstimatedDuration
    ) {
        self.announcedAt = announcedAt
        self.updatedAt = updatedAt ?? announcedAt
        self.updaterName = Self.normalizedUpdaterName(updaterName)
        self.estimatedDuration = max(1, estimatedDuration)
    }

    public var isActive: Bool {
        announcedAt != nil
    }

    public mutating func begin(
        updaterName: String? = nil,
        at date: Date = .now,
        estimatedDuration: TimeInterval = Self.defaultEstimatedDuration
    ) {
        announcedAt = date
        updatedAt = date
        self.updaterName = Self.normalizedUpdaterName(updaterName)
        self.estimatedDuration = max(1, estimatedDuration)
    }

    public mutating func tick(at date: Date = .now) {
        guard isActive else { return }
        updatedAt = date
    }

    public var estimatedProgress: Int? {
        guard let announcedAt, let updatedAt else { return nil }
        let fraction = max(0, updatedAt.timeIntervalSince(announcedAt)) / estimatedDuration
        return min(95, max(0, Int(floor(fraction * 100))))
    }

    public var estimatedSecondsRemaining: Int? {
        guard let announcedAt, let updatedAt else { return nil }
        let remaining = estimatedDuration - updatedAt.timeIntervalSince(announcedAt)
        guard remaining > 0 else { return nil }
        return max(1, Int(ceil(remaining)))
    }

    public mutating func finish() {
        announcedAt = nil
        updatedAt = nil
        updaterName = nil
    }

    @discardableResult
    public mutating func expire(
        at date: Date = .now,
        timeout: TimeInterval = Self.defaultTimeout
    ) -> Bool {
        guard let announcedAt, date.timeIntervalSince(announcedAt) >= timeout else {
            return false
        }
        self.announcedAt = nil
        updatedAt = nil
        updaterName = nil
        return true
    }

    private static func normalizedUpdaterName(_ value: String?) -> String? {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return normalized.isEmpty ? nil : normalized
    }
}
