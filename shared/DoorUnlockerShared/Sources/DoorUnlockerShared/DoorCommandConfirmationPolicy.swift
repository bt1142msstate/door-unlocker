import Foundation

public enum DoorCommandConfirmationPolicy {
    /// Absolute deadlines from command dispatch. Notifications remain the primary path;
    /// these reads only recover a dropped transition or final-state notification.
    public static let fallbackReadDeadlines: [Duration] = [
        .milliseconds(300),
        .milliseconds(1_200)
    ]

    public static let failureDeadline: Duration = .milliseconds(2_500)
}
