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
            return "Storage needs service"
        }
        if phase.isKnownControllerConnectionInProgress {
            return "Connecting"
        }
        switch phase {
        case .starting:
            return "Starting Bluetooth"
        case .bluetoothOff:
            return "Bluetooth is off"
        case .permissionNeeded:
            return "Bluetooth access needed"
        case .unsupported:
            return "Bluetooth unsupported"
        case .bluetoothResetting:
            return "Resetting Bluetooth"
        case .offline:
            return "Controller offline"
        case .scanning:
            return "Looking for controller"
        case .connecting, .discovering, .restoring:
            return "Connecting"
        case .pairingRequired:
            if controller.isPairingPending {
                return "Waiting for approval"
            }
            if controller.canPair {
                return "Ready to pair"
            }
            return "Pairing required"
        case .authenticating, .synchronizing, .preparingSecureControl:
            return "Securing connection"
        case .ready:
            return "Ready"
        case .updatingFirmware:
            return controller.isFirmwareUpdateObservedFromAnotherDevice
                ? "Updating from another device"
                : "Updating controller"
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
            return controller.hasCurrentConnectionRoster
                ? controller.connectedDevicesTitle
                : "Lock state is synced"
        case .updatingFirmware:
            return controller.isFirmwareUpdateObservedFromAnotherDevice
                ? "Reconnecting automatically when the update finishes."
                : controller.firmwareUpdateStatus
        }
    }
}
