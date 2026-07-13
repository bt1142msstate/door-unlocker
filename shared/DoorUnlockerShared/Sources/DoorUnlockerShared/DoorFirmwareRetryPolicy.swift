public enum DoorFirmwareRetryPolicy {
    public static let maximumAutomaticUploadAttempts = 3

    public enum FailureDisposition: Equatable, Sendable {
        case retryable
        case terminal
    }

    public static func shouldAutomaticallyRetry(
        journal: DoorFirmwareUpdateJournal?,
        errorMessage: String
    ) -> Bool {
        guard let journal,
              journal.attemptCount < maximumAutomaticUploadAttempts else {
            return false
        }

        return disposition(for: errorMessage) == .retryable
    }

    public static func disposition(for errorMessage: String) -> FailureDisposition {
        let normalized = errorMessage.lowercased()
        let terminalFragments = [
            "crc",
            "signature",
            "validation",
            "hashing failed",
            "hash type",
            "invalid object",
            "operation failed",
            "unsupported",
            "firmware targets",
            "package is missing",
            "package changed"
        ]
        return terminalFragments.contains { normalized.contains($0) } ? .terminal : .retryable
    }
}
