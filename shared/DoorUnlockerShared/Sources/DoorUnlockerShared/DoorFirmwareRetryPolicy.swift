public enum DoorFirmwareRetryPolicy {
    public static let maximumAutomaticUploadAttempts = 3

    public static func shouldAutomaticallyRetry(
        journal: DoorFirmwareUpdateJournal?,
        errorMessage: String
    ) -> Bool {
        guard let journal,
              journal.attemptCount < maximumAutomaticUploadAttempts else {
            return false
        }

        let normalized = errorMessage.lowercased()
        let terminalFragments = [
            "crc",
            "signature",
            "validation",
            "invalid object",
            "unsupported",
            "package is missing",
            "package changed"
        ]
        return !terminalFragments.contains { normalized.contains($0) }
    }
}
