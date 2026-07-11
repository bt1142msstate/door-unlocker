import DoorUnlockerShared
import DoorUnlockerCore

extension DoorAdminStore {
    var stateTitle: String {
        if controllerHealthStatus == "storage_fault" { return "Controller Needs Service" }
        guard isDisplayedControllerStateAuthoritative else {
            switch sessionAssessment.phase {
            case .bluetoothOff: return "Bluetooth Off"
            case .permissionNeeded: return "Bluetooth Access Needed"
            case .unsupported: return "Bluetooth Unsupported"
            case .updatingFirmware: return "Updating Controller"
            case .pairingRequired: return "Pairing Required"
            case .offline: return "Controller Offline"
            default: return "Connecting"
            }
        }
        return status.stateTitle == "Unknown" ? "Ready" : status.stateTitle
    }

    var controllerStatusTitle: String {
        if controllerHealthStatus == "storage_fault" { return "Controller storage needs service" }
        if status.hasPendingRequest { return "Pairing request" }
        if isConnected && !isUSBControllerValidated { return "Validating USB-C controller" }

        switch sessionAssessment.phase {
        case .starting: return "Bluetooth is starting"
        case .bluetoothOff: return "Bluetooth is off"
        case .permissionNeeded: return "Bluetooth access is needed"
        case .unsupported: return "Bluetooth is not supported"
        case .bluetoothResetting: return "Bluetooth is resetting"
        case .offline: return "Controller is offline"
        case .scanning: return "Looking for the controller"
        case .connecting: return "Connecting to the controller"
        case .discovering: return "Checking controller features"
        case .restoring: return "Restoring the controller link"
        case .pairingRequired: return "Pairing is required"
        case .authenticating: return "Verifying the secure link"
        case .synchronizing: return "Syncing the controller state"
        case .preparingSecureControl: return "Preparing secure control"
        case .ready: return "Controller ready"
        case .updatingFirmware: return "Updating the controller"
        }
    }

    var controllerStatusDetail: String {
        if controllerHealthStatus == "storage_fault" {
            return "Secure control is disabled because trusted-device storage is unavailable. Repair storage over USB-C."
        }
        if isConnected && !isUSBControllerValidated {
            return "The serial link is open. Waiting for the Door Unlocker protocol response."
        }

        switch sessionAssessment.phase {
        case .ready:
            let transport = isUSBControllerValidated ? "USB-C" : "wireless"
            let roster = hasCurrentConnectionRoster
                ? " Connected \(status.connectedCount)/\(max(status.maxConnections, 4))."
                : " The connected-device list is syncing."
            return "The current lock state is synced over \(transport).\(roster)"
        case .offline:
            return "The displayed lock state is not current. The app will reconnect automatically."
        case .scanning:
            return "The app is scanning for the saved controller nearby."
        case .connecting:
            return "The controller was found and the Bluetooth link is opening."
        case .discovering:
            return "The app is preparing the controller's secure control channels."
        case .authenticating:
            return "The controller is connected while the Mac verifies its trusted signing key."
        case .synchronizing:
            return "The secure link is open. Waiting for the controller's current lock state."
        case .preparingSecureControl:
            return "The current state is synced. Requesting fresh one-time command material."
        case .pairingRequired:
            return "Connect USB-C or use another trusted device to approve this Mac."
        case .updatingFirmware:
            return firmwareUpdateStatus
        default:
            return "The app will make secure control available when the controller is ready."
        }
    }

    var controllerStatusSymbol: String {
        if status.hasPendingRequest { return "person.badge.key.fill" }
        if isConnected && !isUSBControllerValidated { return "cable.connector" }
        switch sessionAssessment.phase {
        case .ready: return "checkmark.circle.fill"
        case .pairingRequired: return "key.fill"
        case .bluetoothOff, .permissionNeeded, .unsupported: return "exclamationmark.triangle.fill"
        case .updatingFirmware: return "arrow.triangle.2.circlepath"
        default: return "antenna.radiowaves.left.and.right"
        }
    }

    var connectionSummaryTitle: String {
        if isUSBControllerValidated { return "USB-C connected" }
        if isConnected { return "Validating USB-C" }
        return controllerStatusTitle
    }

    var connectionSummaryDetail: String {
        controllerStatusDetail
    }

    var wirelessConnectionDisplayValue: String {
        switch sessionAssessment.phase {
        case .ready: return "Ready"
        case .offline: return "Offline"
        case .authenticating: return "Authenticating"
        case .synchronizing: return "Syncing state"
        case .preparingSecureControl: return "Preparing control"
        default: return wirelessConnectionState
        }
    }

    var wirelessConnectionDisplaySymbol: String {
        sessionAssessment.phase == .ready
            ? "checkmark.circle.fill"
            : "antenna.radiowaves.left.and.right"
    }

    var isWirelessConnectionDisplayReady: Bool {
        !isUSBControllerValidated && sessionAssessment.phase == .ready
    }

    var connectedDevicesCountText: String {
        guard hasCurrentConnectionRoster else { return "--/\(max(status.maxConnections, 4))" }
        return "\(displayedStatus.connectedCount)/\(max(displayedStatus.maxConnections, 4))"
    }

    var trustedDeviceRosterSummary: TrustedDeviceRosterSummary {
        TrustedDeviceRosterSummary(
            reportedTrustedCount: status.pairedCount,
            reportedMaximumCount: status.maxPairs,
            loadedDeviceCount: pairedDevices.count,
            hasTrustedLocalDevice: hasTrustedMacController
        )
    }

    var trustedDevicesCountText: String {
        trustedDeviceRosterSummary.countText
    }

    var connectedDevicesEmptyMessage: String {
        guard hasCurrentConnectionRoster else {
            return "Connected devices will refresh after the controller state is synchronized."
        }
        return displayedStatus.connectedCount > 0
            ? "Connected devices are identifying."
            : "No devices are connected."
    }
}
