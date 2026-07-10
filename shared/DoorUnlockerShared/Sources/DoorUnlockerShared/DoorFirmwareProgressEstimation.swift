import Foundation

public enum DoorFirmwareProgressEstimation {
    public static func secondsRemaining(
        progress: Int,
        packageBytes: Int,
        averageBytesPerSecond: Double,
        elapsedUploadTime: TimeInterval?
    ) -> Int? {
        guard progress > 0, progress < 100 else {
            return progress >= 100 ? 0 : nil
        }

        let remainingFraction = Double(100 - progress) / 100
        if packageBytes > 0, averageBytesPerSecond > 0 {
            return max(1, Int(ceil(Double(packageBytes) * remainingFraction / averageBytesPerSecond)))
        }

        guard let elapsedUploadTime, elapsedUploadTime > 0 else { return nil }
        let completedFraction = Double(progress) / 100
        return max(1, Int(ceil(elapsedUploadTime * remainingFraction / completedFraction)))
    }
}
