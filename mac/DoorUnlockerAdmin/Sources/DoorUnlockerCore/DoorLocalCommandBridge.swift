import Foundation

public enum DoorLocalCommandBridge {
    public static let appBundleIdentifier = "io.github.bt1142msstate.DoorUnlockerAdmin"
    public static let sender = "door-unlocker-cli"
    public static let commandKey = "command"
    public static let argumentKey = "argument"
    public static let notificationName = Notification.Name("io.github.bt1142msstate.DoorUnlockerAdmin.command")
}
