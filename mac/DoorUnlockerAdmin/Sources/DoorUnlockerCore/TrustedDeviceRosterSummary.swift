public struct TrustedDeviceRosterSummary: Equatable, Sendable {
    public let trustedCount: Int
    public let maximumCount: Int
    public let loadedDeviceCount: Int

    public init(
        reportedTrustedCount: Int,
        reportedMaximumCount: Int,
        loadedDeviceCount: Int,
        hasTrustedLocalDevice: Bool
    ) {
        let loadedCount = max(loadedDeviceCount, 0)
        let localCount = hasTrustedLocalDevice ? 1 : 0
        trustedCount = max(reportedTrustedCount, loadedCount, localCount, 0)
        maximumCount = max(reportedMaximumCount, trustedCount, 4)
        self.loadedDeviceCount = loadedCount
    }

    public var countText: String {
        "\(trustedCount)/\(maximumCount)"
    }

    public var isRosterIncomplete: Bool {
        loadedDeviceCount < trustedCount
    }
}
