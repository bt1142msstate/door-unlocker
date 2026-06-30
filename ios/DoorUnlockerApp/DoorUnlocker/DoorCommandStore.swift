import Foundation

enum DoorSystemCommand: String {
    case lock = "LOCK"
    case unlock = "UNLOCK"
    case toggle = "TOGGLE"

    var url: URL {
        DoorWidgetCommandTokenStore.commandURL(action: rawValue.lowercased())
    }
}

extension Notification.Name {
    static let doorCommandRequested = Notification.Name("DoorCommandRequested")
}

enum DoorCommandStore {
    private static let pendingCommandKey = "PendingDoorCommand"

    static func request(_ command: DoorSystemCommand) {
        DoorStatusStore.sharedDefaults.set(command.rawValue, forKey: pendingCommandKey)
        NotificationCenter.default.post(name: .doorCommandRequested, object: command)
    }

    static func request(from url: URL) {
        guard DoorWidgetCommandTokenStore.isValidWidgetCommandURL(url) else { return }
        guard let command = command(from: url) else { return }
        request(command)
    }

    static func takePendingCommand() -> DoorSystemCommand? {
        guard let rawValue = DoorStatusStore.sharedDefaults.string(forKey: pendingCommandKey),
              let command = DoorSystemCommand(rawValue: rawValue) else {
            return nil
        }

        DoorStatusStore.sharedDefaults.removeObject(forKey: pendingCommandKey)
        return command
    }

    private static func command(from url: URL) -> DoorSystemCommand? {
        guard url.scheme == "doorunlocker" else { return nil }
        let rawAction = url.host ?? url.pathComponents.dropFirst().first

        switch rawAction?.lowercased() {
        case "lock":
            return .lock
        case "unlock":
            return .unlock
        case "toggle":
            return .toggle
        default:
            return nil
        }
    }
}
