import DoorUnlockerShared
import DoorUnlockerCore

extension DoorAdminStore {
    var displayedFirmwareUpdateProgress: Int? {
        isFirmwareUpdateObservedFromAnotherDevice
            ? observedFirmwareUpdate.estimatedProgress
            : firmwareUpdateProgress
    }

    var firmwareUpdateDeviceText: String? {
        if isFirmwareUpdateObservedFromAnotherDevice {
            return observedFirmwareUpdate.updaterName.map { "Updating from \($0)" }
                ?? "Updating from another device"
        }
        if isFirmwareUpdateRunning {
            return "Updating from \(localMacDeviceName)"
        }
        return nil
    }

    var firmwareUpdateETAText: String? {
        let isEstimated = isFirmwareUpdateObservedFromAnotherDevice
        let seconds = isEstimated
            ? observedFirmwareUpdate.estimatedSecondsRemaining
            : firmwareUpdateEstimatedSecondsRemaining
        guard let seconds, seconds > 0 else { return nil }
        let minutes = seconds / 60
        let remainder = seconds % 60
        let duration = minutes == 0 ? "\(seconds)s" : remainder == 0 ? "\(minutes)m" : "\(minutes)m \(remainder)s"
        return isEstimated ? "Estimated \(duration) remaining" : "About \(duration) remaining"
    }

    var stateTitle: String {
        if controllerHealthStatus == "storage_fault" { return "Controller Needs Service" }
        guard isDisplayedControllerStateAuthoritative else {
            switch sessionAssessment.phase {
            case .bluetoothOff: return "Bluetooth Off"
            case .permissionNeeded: return "Bluetooth Access Needed"
            case .unsupported: return "Bluetooth Unsupported"
            case .updatingFirmware:
                return isFirmwareUpdateObservedFromAnotherDevice ? "Updating from Another Device" : "Updating Controller"
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
        if sessionAssessment.phase.isKnownControllerConnectionInProgress {
            return "Connecting"
        }

        switch sessionAssessment.phase {
        case .starting: return "Bluetooth is starting"
        case .bluetoothOff: return "Bluetooth is off"
        case .permissionNeeded: return "Bluetooth access is needed"
        case .unsupported: return "Bluetooth is not supported"
        case .bluetoothResetting: return "Bluetooth is resetting"
        case .offline: return "Controller offline"
        case .scanning: return "Looking for controller"
        case .connecting, .discovering, .restoring: return "Connecting"
        case .pairingRequired: return "Pairing required"
        case .authenticating, .synchronizing, .preparingSecureControl: return "Securing connection"
        case .ready: return "Ready"
        case .updatingFirmware:
            return isFirmwareUpdateObservedFromAnotherDevice ? "Updating from another device" : "Updating controller"
        }
    }

    var controllerStatusDetail: String {
        if controllerHealthStatus == "storage_fault" {
            return "Secure control is disabled because trusted-device storage is unavailable. Repair storage over USB-C."
        }
        if isConnected && !isUSBControllerValidated {
            return "The serial link is open. Waiting for the Door Unlocker protocol response."
        }
        if sessionAssessment.phase.isKnownControllerConnectionInProgress {
            return "Opening your saved secure controller connection."
        }

        switch sessionAssessment.phase {
        case .ready:
            if hasCurrentConnectionRoster {
                return "\(status.connectedCount) of \(max(status.maxConnections, 4)) devices connected"
            }
            return isUSBControllerValidated ? "Connected over USB-C" : "Lock state is synced"
        case .offline:
            return "The displayed lock state is not current. The app will reconnect automatically."
        case .scanning:
            return "The app is scanning for the saved controller nearby."
        case .connecting, .discovering, .authenticating, .synchronizing, .preparingSecureControl:
            return "Opening your saved secure controller connection."
        case .pairingRequired:
            return "Connect USB-C or use another trusted device to approve this Mac."
        case .updatingFirmware:
            return isFirmwareUpdateObservedFromAnotherDevice
                ? "Reconnecting automatically when the update finishes."
                : firmwareUpdateStatus
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
