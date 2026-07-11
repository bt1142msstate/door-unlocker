import DoorUnlockerShared
import Foundation

@MainActor
struct ControllerStatusPresentation {
    let icon: String
    let isSearching: Bool
    let title: String
    let detail: String

    init(controller: DoorUnlockerController) {
        let phase = controller.sessionAssessment.phase
        icon = controller.controllerHealthStatus == "storage_fault"
            ? "exclamationmark.triangle.fill"
            : Self.icon(for: phase)
        isSearching = Self.isSearching(phase)
        title = Self.title(for: phase, controller: controller)
        detail = Self.detail(for: phase, controller: controller)
    }

    private static func icon(for phase: DoorControllerSessionPhase) -> String {
        switch phase {
        case .ready:
            return "checkmark.circle.fill"
        case .pairingRequired:
            return "key.fill"
        case .bluetoothOff, .permissionNeeded, .unsupported:
            return "exclamationmark.triangle.fill"
        case .updatingFirmware:
            return "arrow.triangle.2.circlepath"
        default:
            return "antenna.radiowaves.left.and.right"
        }
    }

    private static func isSearching(_ phase: DoorControllerSessionPhase) -> Bool {
        switch phase {
        case .starting, .bluetoothResetting, .scanning, .connecting, .discovering,
             .restoring, .authenticating, .synchronizing, .preparingSecureControl:
            return true
        default:
            return false
        }
    }

    private static func title(
        for phase: DoorControllerSessionPhase,
        controller: DoorUnlockerController
    ) -> String {
        if controller.controllerHealthStatus == "storage_fault" {
            return "Controller storage needs service."
        }
        if phase.isKnownControllerConnectionInProgress {
            return "Connecting to the controller."
        }
        switch phase {
        case .starting:
            return "Bluetooth is starting."
        case .bluetoothOff:
            return "Bluetooth is off."
        case .permissionNeeded:
            return "Bluetooth access is needed."
        case .unsupported:
            return "Bluetooth is not supported."
        case .bluetoothResetting:
            return "Bluetooth is resetting."
        case .offline:
            return "Not connected to the controller."
        case .scanning:
            return "Looking for the controller."
        case .connecting, .discovering, .restoring:
            return "Connecting to the controller."
        case .pairingRequired:
            if controller.isPairingPending {
                return "Waiting for pairing approval."
            }
            if controller.canPair {
                return "This iPhone can pair now."
            }
            return "Pairing is required."
        case .authenticating, .synchronizing, .preparingSecureControl:
            return "Connecting to the controller."
        case .ready:
            return "Controller is ready."
        case .updatingFirmware:
            return "Updating the controller."
        }
    }

    private static func detail(
        for phase: DoorControllerSessionPhase,
        controller: DoorUnlockerController
    ) -> String {
        if controller.controllerHealthStatus == "storage_fault" {
            return "Secure control is disabled because trusted-device storage is unavailable. Connect USB-C and repair storage."
        }
        if phase.isKnownControllerConnectionInProgress {
            return "Opening your saved secure controller connection."
        }
        switch phase {
        case .starting:
            return "The app is waiting for Bluetooth to become available."
        case .bluetoothOff:
            return "Turn on Bluetooth to control the lock."
        case .permissionNeeded:
            return "Allow Bluetooth access in Settings to connect."
        case .unsupported:
            return "This iPhone cannot control the lock over Bluetooth."
        case .bluetoothResetting:
            return "The app will reconnect when Bluetooth is ready."
        case .offline:
            return "The last displayed lock state is not current. The app will reconnect automatically."
        case .scanning:
            return "The app is scanning for your saved lock nearby."
        case .connecting, .discovering, .restoring:
            return "Opening your saved secure controller connection."
        case .pairingRequired:
            if controller.isPairingPending {
                return controller.isPairingThisPhone
                    ? "Approve the code shown here from a trusted device or USB-C."
                    : "Enter the code shown on the new device to approve pairing."
            }
            return "Use a trusted device or USB-C to approve this iPhone."
        case .authenticating, .synchronizing, .preparingSecureControl:
            return "Opening your saved secure controller connection."
        case .ready:
            return "The current lock state is synced and secure control is ready."
        case .updatingFirmware:
            return controller.firmwareUpdateStatus
        }
    }
}
