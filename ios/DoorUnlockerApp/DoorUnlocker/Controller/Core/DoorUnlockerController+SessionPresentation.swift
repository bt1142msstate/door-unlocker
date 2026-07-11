import CoreBluetooth
import CoreLocation
import DoorUnlockerDFU
import DoorUnlockerShared
import Foundation
import ActivityKit
import LocalAuthentication
import UIKit
import UserNotifications
import WidgetKit

extension DoorUnlockerController {
    var isConnectedToController: Bool {
        pairingCharacteristic != nil && peripheral?.state == .connected
    }

    var isPaired: Bool {
        pairingState == "Paired"
    }

    var hasDiscoveredControllerCharacteristics: Bool {
        commandCharacteristic != nil
            && stateCharacteristic != nil
            && pairingCharacteristic != nil
            && controlCharacteristic != nil
    }

    var isReady: Bool {
        hasDiscoveredControllerCharacteristics
            && peripheral?.state == .connected
            && hasTrustedPairingForSecureCommand
    }

    var isPreparingKnownController: Bool {
        guard bluetoothState == "On",
              !isReady,
              hasKnownPairedController else {
            return false
        }

        switch connectionState {
        case "Scanning", "Connecting", "Discovering", "Reconnecting", "Restoring", "Starting", "Known controller", "Disconnected":
            return true
        default:
            return false
        }
    }

    var isDoorCommandReady: Bool {
        isReady && hasFreshFastCommandMaterial
    }

    var hasFreshFastCommandMaterial: Bool {
        hasFastCommandNonce || hasPreparedFastDoorCommandPayloads
    }

    var hasFastCommandNonce: Bool {
        fastCommandNonce != nil
    }

    var hasPreparedFastDoorCommandPayloads: Bool {
        !preparedFastDoorCommandPayloads.isEmpty
    }

    var canAcceptDoorCommand: Bool {
        pendingFreshNonceDoorCommand == nil && sessionAssessment.canDispatchImmediately
    }

    var visibleLastError: String? {
        guard let lastError else { return nil }

        if shouldHideFirmwareUpdateTransientError(lastError) {
            return nil
        }

        if shouldHideTransientStartupError(lastError) {
            return nil
        }

        return lastError
    }

    var isDoorCommandQueuedForSecureLink: Bool {
        pendingFreshNonceDoorCommand != nil
    }

    var secureLinkStatusTitle: String {
        guard isReady, !isDoorCommandReady else { return "Controller is ready." }

        if controlCharacteristic == nil {
            return "Opening secure control."
        }

        return "Preparing secure control."
    }

    var secureLinkStatusDetail: String {
        guard isReady, !isDoorCommandReady else {
            return "Bluetooth is on. This iPhone is paired with the lock."
        }

        if controlCharacteristic == nil {
            return "The app is opening the controller control channel."
        }

        return "The app is requesting a fresh encrypted command nonce from the controller."
    }

    var connectedDevicesTitle: String {
        guard hasCurrentConnectionRoster else {
            return isControllerOnline ? "Connected devices syncing" : "Controller offline"
        }
        return "\(connectedDeviceCount) of \(displayedMaximumConnectedDeviceCount) connected"
    }

    var connectedDevicesDetail: String {
        guard hasCurrentConnectionRoster else {
            return isControllerOnline
                ? "Waiting for the controller's current device list."
                : "The device list will refresh after the controller reconnects."
        }

        if connectedDevices.isEmpty {
            if isReady || canAcceptDoorCommand {
                return "This iPhone is ready. Other devices will appear when identified."
            }
            return displayedConnectedDeviceCount > 0 ? "Connected devices are identifying." : "No other devices are connected."
        }

        return connectedDevices.map(\.displayName).joined(separator: ", ")
    }

    var shouldShowConnectedDevicesSummary: Bool {
        hasCurrentConnectionRoster || isControllerOnline || hasKnownController
    }

    var displayedConnectedDeviceCount: Int {
        hasCurrentConnectionRoster ? connectedDeviceCount : 0
    }

    var displayedMaximumConnectedDeviceCount: Int {
        max(maximumConnectedDeviceCount, 4)
    }

    var hasTrustedPairingForSecureCommand: Bool {
        (isPaired || hasKnownPairedController) && !hasRejectedCurrentSecurePairing
    }

    var isSecureCommandWriteReady: Bool {
        commandCharacteristic != nil &&
            controlCharacteristic != nil &&
            peripheral?.state == .connected &&
            hasTrustedPairingForSecureCommand
    }

    var canQueueDoorCommandForKnownController: Bool {
        guard hasTrustedPairingForSecureCommand else {
            return false
        }

        if isSecureCommandWriteReady {
            return true
        }

        if central?.state == .poweredOn {
            switch connectionState {
            case "Scanning", "Connecting", "Discovering", "Reconnecting", "Restoring", "Starting", "Known controller", "Disconnected":
                return true
            default:
                return peripheral?.state == .connected || peripheral?.state == .connecting
            }
        }

        guard hasKnownController,
              bluetoothState == "Starting" || bluetoothState == "Unknown" else {
            return false
        }

        return central == nil || central?.state == .unknown || central?.state == .resetting
    }

    var canQueueControllerSettingForKnownController: Bool {
        isReady || canQueueDoorCommandForKnownController
    }

    var controllerSettingPendingStatusTitle: String {
        canQueueControllerSettingForKnownController ? "Setting..." : "Waiting for controller"
    }

    var hasKnownController: Bool {
        peripheral != nil || UserDefaults.standard.string(forKey: Self.knownPeripheralIdentifierKey) != nil
    }

    var shouldDeferRefreshScan: Bool {
        if isFirmwareUpdateRunning {
            return true
        }

        if peripheral?.state == .connecting {
            return true
        }

        if peripheral?.state == .connected,
           commandCharacteristic == nil
            || stateCharacteristic == nil
            || pairingCharacteristic == nil
            || controlCharacteristic == nil {
            return true
        }

        switch connectionState {
        case "Connecting", "Discovering", "Reconnecting", "Restoring", "Known controller", "Starting":
            return true
        default:
            return false
        }
    }
}
