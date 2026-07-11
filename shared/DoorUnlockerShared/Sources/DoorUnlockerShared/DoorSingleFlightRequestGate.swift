import Foundation

public struct DoorSingleFlightRequestGate: Equatable, Sendable {
    public private(set) var generation: UInt64 = 0
    public private(set) var isInFlight = false
    public private(set) var lastRequestUptime: TimeInterval?

    public init() {}

    public mutating func begin(
        at uptime: TimeInterval,
        minimumInterval: TimeInterval
    ) -> UInt64? {
        guard !isInFlight else { return nil }
        if let lastRequestUptime,
           uptime < lastRequestUptime + max(0, minimumInterval) - 1e-9 {
            return nil
        }

        generation &+= 1
        isInFlight = true
        lastRequestUptime = uptime
        return generation
    }

    public mutating func complete() {
        generation &+= 1
        isInFlight = false
    }

    @discardableResult
    public mutating func expire(generation expectedGeneration: UInt64) -> Bool {
        guard isInFlight, generation == expectedGeneration else { return false }
        complete()
        return true
    }

    public mutating func invalidate() {
        complete()
        lastRequestUptime = nil
    }
}
