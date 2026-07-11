import CoreBluetooth
import DoorUnlockerCore
import DoorUnlockerDFU
import DoorUnlockerShared
import Foundation
import os

extension DoorAdminStore {
    var selectedPort: SerialPortCandidate? {
        ports.first { $0.id == selectedPortID }
    }

    var selectedDevice: PairedDevice? {
        pairedDevices.first { $0.id == selectedDeviceID }
    }

    var isWirelessConnected: Bool {
        peripheral?.state == .connected
    }

    var isWirelessSessionActive: Bool {
        if let peripheral, peripheral.state == .connecting || peripheral.state == .connected {
            return true
        }
        return wirelessConnectionState == "Scanning"
    }

    var isWirelessGattReady: Bool {
        peripheral?.state == .connected
            && commandCharacteristic != nil
            && stateCharacteristic != nil
            && pairingCharacteristic != nil
            && controlCharacteristic != nil
    }

    var isWirelessReady: Bool {
        isWirelessGattReady && hasTrustedWirelessPairingForSecureCommand
    }

    var isWirelessDoorCommandReady: Bool {
        isWirelessReady && hasFreshFastCommandMaterial
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

    var canUseWirelessFallback: Bool {
        !isConnected && !isUSBConnectInFlight &&
            (hasTrustedWirelessPairingForSecureCommand || hasKnownWirelessController)
    }

    var hasTrustedWirelessPairingForSecureCommand: Bool {
        hasTrustedMacController && !hasRejectedCurrentSecurePairing
    }

    var hasKnownWirelessController: Bool {
        peripheral != nil || UserDefaults.standard.string(forKey: Self.knownPeripheralIdentifierKey) != nil
    }

    var canQueueWirelessCommandForKnownController: Bool {
        guard !isConnected,
              !isUSBConnectInFlight,
              hasTrustedWirelessPairingForSecureCommand else {
            return false
        }

        if isWirelessReady {
            return true
        }

        if central?.state == .poweredOn {
            return true
        }

        guard hasKnownWirelessController,
              bluetoothState == "Starting" || bluetoothState == "Unknown" else {
            return false
        }

        return central == nil || central?.state == .unknown || central?.state == .resetting
    }

    var wirelessStopReason: String {
        isConnected || isUSBConnectInFlight ? "USB-C active" : "Idle"
    }

    func shouldHideTransientStartupError(_ error: String) -> Bool {
        guard canSendDoorCommand || isDoorCommandQueued || isWirelessQueueReady else {
            return false
        }

        let normalizedError = error.lowercased()
        let transientFragments = [
            "not connected",
            "connection failed",
            "wirelessly",
            "required bluetooth characteristics were not found",
            "door service not found over bluetooth",
            "fresh secure command"
        ]

        return transientFragments.contains { normalizedError.contains($0) }
    }

    static func currentEpochSeconds() -> UInt64 {
        UInt64(max(0, Date().timeIntervalSince1970.rounded(.down)))
    }

    var localMacDeviceName: String {
        DoorDeviceNameNormalizer.normalized(Host.current().localizedName ?? "Mac", fallback: "Mac")
    }

    var localUSBDeviceDisplayName: String {
        "\(localMacDeviceName) (USB-C)"
    }

    var localUSBDevice: ConnectedControllerDevice {
        ConnectedControllerDevice(
            slot: 0,
            handle: Self.localUSBDeviceHandle,
            name: localUSBDeviceDisplayName,
            isTrustedName: true
        )
    }

    static func appUnlockCommandText() -> String {
        let deviceName = DoorDeviceNameNormalizer.normalized(Host.current().localizedName ?? "Mac", fallback: "Mac")
        return "app unlock \(currentEpochSeconds()) \(deviceName)"
    }

    static func appLockCommandText() -> String {
        "app lock \(currentEpochSeconds())"
    }

    var canSendDoorCommand: Bool {
        sessionAssessment.canDispatchImmediately
    }

    var isWirelessQueueReady: Bool {
        sessionAssessment.canQueueCommand && !isConnected
    }

    var displayedStatus: ControllerStatus {
        if isUSBControllerValidated {
            return statusIncludingLocalUSBConnection(status)
        }

        guard hasCurrentConnectionRoster else {
            return statusRemovingLocalUSBConnection(status)
        }
        return statusRemovingLocalUSBConnection(status)
    }

    var primaryConnectionTitle: String {
        if isConnected || isUSBConnectInFlight {
            return "USB-C"
        }
        if isWirelessReady {
            return "Wireless"
        }
        if isWirelessQueueReady {
            return "Wireless"
        }
        return "Disconnected"
    }
}
