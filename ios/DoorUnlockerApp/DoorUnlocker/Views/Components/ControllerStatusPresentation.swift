import Foundation

@MainActor
struct ControllerStatusPresentation {
    let icon: String
    let isSearching: Bool
    let title: String
    let detail: String

    init(controller: DoorUnlockerController) {
        icon = ControllerStatusIcon.name(for: controller)
        isSearching = ControllerStatusSearch.isSearching(controller)
        title = ControllerStatusTitle.text(for: controller)
        detail = ControllerStatusDetail.text(for: controller)
    }
}

@MainActor
private enum ControllerStatusIcon {
    static func name(for controller: DoorUnlockerController) -> String {
        if controller.canAcceptDoorCommand {
            return "checkmark.circle.fill"
        }

        if controller.bluetoothState != "On" {
            return "exclamationmark.triangle.fill"
        }

        if controller.isPairingPending || controller.needsUsbPairingMode || controller.canPair {
            return "key.fill"
        }

        return "antenna.radiowaves.left.and.right"
    }
}

@MainActor
private enum ControllerStatusSearch {
    static func isSearching(_ controller: DoorUnlockerController) -> Bool {
        if controller.canAcceptDoorCommand {
            return false
        }

        if controller.isPreparingKnownController {
            return true
        }

        switch controller.connectionState {
        case "Scanning", "Connecting", "Discovering", "Reconnecting", "Restoring", "Starting", "Known controller":
            return controller.bluetoothState == "On"
        default:
            return false
        }
    }
}

@MainActor
private enum ControllerStatusTitle {
    static func text(for controller: DoorUnlockerController) -> String {
        if controller.canAcceptDoorCommand {
            return controller.isReady ? "Controller is ready." : "Ready for your tap."
        }

        if controller.isReady {
            return controller.secureLinkStatusTitle
        }

        if controller.isPreparingKnownController {
            return "Opening secure link."
        }

        if controller.bluetoothState != "On" {
            return BluetoothStatusText.title(for: controller.bluetoothState)
        }

        if let title = connectionTitle(for: controller.connectionState) {
            return title
        }

        if controller.isPairingPending {
            return "Waiting for pairing approval."
        }

        if controller.canPair {
            return "This iPhone can pair now."
        }

        if controller.needsUsbPairingMode {
            return "Pairing is locked."
        }

        return PairingStatusText.sentence(for: controller.pairingState)
    }

    private static func connectionTitle(for state: String) -> String? {
        switch state {
        case "Scanning":
            return "Bluetooth is scanning."
        case "Connecting":
            return "Connecting to the controller."
        case "Discovering":
            return "Checking controller features."
        case "Reconnecting":
            return "Reconnecting to the controller."
        case "Restoring":
            return "Restoring the controller link."
        case "Disconnected":
            return "The controller is disconnected."
        case "Known controller":
            return "Opening the saved controller link."
        case "Bluetooth off":
            return "Bluetooth is off."
        case "Permission needed":
            return "Bluetooth permission is needed."
        case "Unsupported":
            return "Bluetooth is not supported."
        case "Resetting":
            return "Bluetooth is resetting."
        case "Starting":
            return "Bluetooth is starting."
        case "Ready":
            return nil
        default:
            return state == "Ready" ? nil : ConnectionStatusText.sentence(for: state)
        }
    }
}

@MainActor
private enum ControllerStatusDetail {
    static func text(for controller: DoorUnlockerController) -> String {
        if controller.canAcceptDoorCommand {
            return controller.isReady
                ? "Bluetooth is on. This iPhone is paired with the lock."
                : "The app will send securely as soon as the trusted Bluetooth link opens."
        }

        if controller.isReady {
            return controller.secureLinkStatusDetail
        }

        if controller.isPreparingKnownController {
            return "The app is opening the saved controller and preparing encrypted control."
        }

        if controller.bluetoothState != "On" {
            return BluetoothStatusText.detail(for: controller.bluetoothState)
        }

        if let detail = connectionDetail(for: controller.connectionState) {
            return detail
        }

        if controller.isPairingPending {
            return controller.isPairingThisPhone
                ? "Approve the code shown here from a trusted device or USB-C."
                : "Enter the code shown on the new device to approve pairing."
        }

        if controller.canPair {
            return "Tap Pair This iPhone, then approve the code from a trusted device or USB-C."
        }

        if controller.needsUsbPairingMode {
            return "Use a trusted device or USB-C to allow new-device pairing."
        }

        return "The controller is connected. \(PairingStatusText.sentence(for: controller.pairingState))"
    }

    private static func connectionDetail(for state: String) -> String? {
        switch state {
        case "Scanning":
            return "Looking for your lock nearby."
        case "Connecting":
            return "The app found the controller and is opening the link."
        case "Discovering":
            return "The app is preparing secure lock control."
        case "Reconnecting":
            return "The app is trying to restore control automatically."
        case "Restoring":
            return "iOS is handing the saved Bluetooth link back to the app."
        case "Disconnected":
            return "The app will reconnect when it sees the controller again."
        case "Known controller":
            return "The app found the saved lock and is preparing control."
        case "Bluetooth off":
            return "Turn on Bluetooth to control the lock."
        case "Permission needed":
            return "Allow Bluetooth access in Settings to connect."
        case "Unsupported":
            return "This device cannot control the lock over Bluetooth."
        case "Resetting":
            return "The app will reconnect when Bluetooth is ready."
        case "Starting":
            return "The app is waiting for Bluetooth to become ready."
        case "Ready":
            return nil
        default:
            return state == "Ready" ? nil : "Bluetooth is on. \(ConnectionStatusText.sentence(for: state))"
        }
    }
}

private enum BluetoothStatusText {
    static func title(for state: String) -> String {
        switch state {
        case "On":
            return "Bluetooth is on."
        case "Off":
            return "Bluetooth is off."
        case "Unauthorized":
            return "Bluetooth permission is needed."
        case "Unsupported":
            return "Bluetooth is not supported."
        case "Resetting":
            return "Bluetooth is resetting."
        case "Starting":
            return "Bluetooth is starting."
        case "Unknown":
            return "Bluetooth status is unknown."
        default:
            return "Bluetooth is \(state.lowercased())."
        }
    }

    static func detail(for state: String) -> String {
        switch state {
        case "On":
            return "The app can look for the lock."
        case "Off":
            return "Turn on Bluetooth to control the lock."
        case "Unauthorized":
            return "Allow Bluetooth access in Settings to connect."
        case "Unsupported":
            return "This device cannot control the lock over Bluetooth."
        case "Resetting":
            return "The app will reconnect when Bluetooth is ready."
        case "Starting":
            return "The app is waiting for Bluetooth to become ready."
        case "Unknown":
            return "The app is waiting for iOS to report Bluetooth status."
        default:
            return "The app cannot connect while Bluetooth is unavailable."
        }
    }
}

private enum ConnectionStatusText {
    static func sentence(for state: String) -> String {
        switch state {
        case "Ready":
            return "The controller is ready."
        case "Scanning":
            return "Bluetooth is scanning for the lock."
        case "Connecting":
            return "The app is connecting to the controller."
        case "Discovering":
            return "The app is checking controller features."
        case "Reconnecting":
            return "The app is reconnecting to the controller."
        case "Restoring":
            return "The app is restoring the controller link."
        case "Disconnected":
            return "The controller is disconnected."
        case "Known controller":
            return "The app is opening the saved controller link."
        case "Bluetooth off":
            return "Bluetooth is off."
        case "Permission needed":
            return "Bluetooth permission is needed."
        case "Unsupported":
            return "Bluetooth is not supported."
        case "Resetting":
            return "Bluetooth is resetting."
        case "Starting":
            return "Bluetooth is starting."
        default:
            return "The controller link is being checked."
        }
    }
}

private enum PairingStatusText {
    static func sentence(for state: String) -> String {
        switch state {
        case "Paired":
            return "This iPhone is paired."
        case "Pairing enabled":
            return "Pairing is enabled."
        case "Pairing pending":
            return "Pairing is waiting for trusted approval."
        case "Pairing":
            return "This iPhone is sending a pairing request."
        case "Pairing locked":
            return "Pairing must be enabled by a trusted device or USB-C."
        case "Unknown":
            return "The app is checking pairing."
        default:
            return "The app is checking pairing."
        }
    }
}
