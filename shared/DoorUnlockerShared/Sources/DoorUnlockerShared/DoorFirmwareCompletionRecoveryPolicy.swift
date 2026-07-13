public enum DoorFirmwareCompletionRecoveryPolicy {
    public static func isFinalPartComplete(
        part: Int,
        totalParts: Int,
        progress: Int
    ) -> Bool {
        totalParts > 0 && part == totalParts && progress >= 100
    }

    public static func shouldProbeNormalFirmware(didReportFinalPartComplete: Bool) -> Bool {
        didReportFinalPartComplete
    }
}
