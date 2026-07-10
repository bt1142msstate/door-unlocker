import CoreBluetooth
import DoorUnlockerCore
import DoorUnlockerDFU
import DoorUnlockerShared
import Foundation
import os

extension DoorAdminStore {
    var stateTitle: String {
        let title = status.stateTitle
        if title == "Unknown", canSendDoorCommand {
            return "Ready"
        }
        return title == "Unknown" ? "Disconnected" : title
    }

    var controllerStatusTitle: String {
        if status.hasPendingRequest {
            return "Pairing request"
        }
        if isUSBConnectInFlight && !isConnected {
            return "Opening USB-C"
        }
        if isConnected || isWirelessReady {
            return "Controller ready"
        }
        if isWirelessQueueReady {
            return "Ready for your click"
        }
        if bluetoothState != "On" {
            return "Bluetooth \(bluetoothState)"
        }
        return wirelessConnectionState
    }

    var controllerStatusDetail: String {
        if isWirelessQueueReady {
            return hasKnownWirelessController
                ? "Wireless will send securely as soon as the saved controller link opens"
                : "Wireless will send securely as soon as the trusted controller is found"
        }

        let status = displayedStatus
        return "Connection \(primaryConnectionTitle) - Connected \(status.connectedCount)/\(max(status.maxConnections, 4)) - Trusted \(status.pairedCount)/\(max(status.maxPairs, 4))"
    }

    var controllerStatusSymbol: String {
        if status.hasPendingRequest {
            return "person.badge.key.fill"
        }
        if isUSBConnectInFlight && !isConnected {
            return "cable.connector"
        }
        if isConnected || isWirelessReady {
            return "checkmark.circle.fill"
        }
        if isWirelessQueueReady {
            return "checkmark.circle.fill"
        }
        if bluetoothState != "On" {
            return "exclamationmark.triangle.fill"
        }
        return "antenna.radiowaves.left.and.right"
    }

    var connectionSummaryTitle: String {
        if isConnected {
            return "USB-C connected"
        }
        if isWirelessReady {
            return "Wireless ready"
        }
        if isWirelessQueueReady {
            return "Wireless ready"
        }
        if isWirelessGattReady {
            return "Wireless connected"
        }
        if bluetoothState != "On" {
            return "Bluetooth \(bluetoothState)"
        }
        return wirelessConnectionState
    }

    var connectionSummaryDetail: String {
        if isConnected {
            return "Admin commands and settings use USB-C. Other Bluetooth devices still appear in connected devices."
        }
        if isWirelessReady {
            return "Wireless is connected. The controller serializes commands from multiple trusted devices."
        }
        if isWirelessQueueReady {
            return hasKnownWirelessController
                ? "Commands can queue while the saved controller link opens."
                : "Commands can queue while the Mac scans for the trusted controller."
        }
        if isWirelessGattReady {
            return "Connect USB-C once to trust this Mac for secure wireless commands."
        }
        if bluetoothState != "On" {
            return "Turn Bluetooth on to use wireless control."
        }
        return "USB-C connects automatically when plugged in. Wireless connects on demand so the iPhone stays responsive."
    }

    var wirelessConnectionDisplayValue: String {
        if isWirelessReady || isWirelessQueueReady {
            return "Ready"
        }
        return wirelessConnectionState
    }

    var wirelessConnectionDisplaySymbol: String {
        if isConnected {
            return "pause.circle.fill"
        }
        if isWirelessReady || isWirelessQueueReady {
            return "checkmark.circle.fill"
        }
        return "antenna.radiowaves.left.and.right"
    }

    var isWirelessConnectionDisplayReady: Bool {
        isWirelessReady || isWirelessQueueReady
    }

    var connectedDevicesCountText: String {
        let status = displayedStatus
        return "\(status.connectedCount)/\(max(status.maxConnections, 4))"
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
        if isWirelessQueueReady && statusRemovingLocalUSBConnection(status).connectedDevices.isEmpty {
            return hasKnownWirelessController
                ? "Saved wireless link is ready. Active devices will appear after the controller link opens."
                : "Trusted wireless control is ready. Active devices will appear after the controller is found."
        }

        let status = displayedStatus
        return status.connectedCount > 0 ? "Connected devices are identifying." : "No devices are connected."
    }
}
