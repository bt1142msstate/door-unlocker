import CoreBluetooth
import DoorUnlockerCore
import DoorUnlockerDFU
import DoorUnlockerShared
import Foundation
import os

extension DoorAdminStore {
    func refreshPorts() {
        ports = SerialPortDiscovery.discover()
        if selectedPortID == nil || !ports.contains(where: { $0.id == selectedPortID }) {
            selectedPortID = ports.first?.id
        }
        autoConnectUSBIfAvailable()
    }

    func scanBluetooth() {
        ensureBluetoothCentral()
        recordRuntimeTelemetry("scan_requested", details: "state=\(wirelessConnectionState)", once: false)
        guard let central else {
            wirelessConnectionState = "Starting"
            return
        }

        guard central.state == .poweredOn else {
            updateBluetoothAvailabilityState(central.state)
            return
        }
        guard canUseWirelessFallback else {
            stopWirelessSession(reason: wirelessStopReason)
            return
        }
        if let peripheral, peripheral.state == .connected {
            if isWirelessGattReady {
                return
            }

            wirelessConnectionState = "Discovering"
            stopWirelessScan()
            peripheral.discoverServices([serviceUUID])
            scheduleKnownPeripheralDiscoveryRetry()
            return
        }

        if peripheral?.state == .connecting {
            scheduleKnownPeripheralDiscoveryRetry()
            return
        }

        wirelessReconnectTask?.cancel()
        wirelessReconnectTask = nil
        wirelessKnownPeripheralFallbackTask?.cancel()
        wirelessKnownPeripheralFallbackTask = nil
        lastError = nil
        commandCharacteristic = nil
        stateCharacteristic = nil
        pairingCharacteristic = nil
        controlCharacteristic = nil
        isWirelessStateNotificationEnabled = false
        resetWirelessLinkAuthentication()
        resetWirelessControlNonceRequest()
        stopSecureLinkWatchdog()
        invalidatePreparedFastDoorCommandPayloads(clearNonce: true)
        wirelessPairingState = "Unknown"
        hasConfirmedExpiredAutoLockDeadline = false
        if connectToKnownPeripheralIfPossible() {
            return
        }

        wirelessConnectionState = "Scanning"
        startWirelessScanIfNeeded()
    }

    func startWirelessScanIfNeeded() {
        guard let central, central.state == .poweredOn else { return }

        let allowsDuplicates = false
        if central.isScanning, activeWirelessScanAllowsDuplicates == allowsDuplicates {
            return
        }

        central.stopScan()
        activeWirelessScanAllowsDuplicates = allowsDuplicates
        central.scanForPeripherals(
            withServices: [serviceUUID],
            options: scanOptionsForCurrentMode(allowsDuplicates: allowsDuplicates)
        )
    }

    func stopWirelessScan() {
        central?.stopScan()
        activeWirelessScanAllowsDuplicates = nil
    }

    func ensureBluetoothCentral() {
        guard central == nil else { return }
        central = CBCentralManager(delegate: self, queue: .main)
        recordRuntimeTelemetry("central_created")
    }

    func updateBluetoothAvailabilityState(_ state: CBManagerState) {
        switch state {
        case .poweredOn:
            bluetoothState = "On"
        case .poweredOff:
            bluetoothState = "Off"
            wirelessConnectionState = "Bluetooth off"
        case .unauthorized:
            bluetoothState = "Unauthorized"
            wirelessConnectionState = "Bluetooth permission needed"
        case .unsupported:
            bluetoothState = "Unsupported"
            wirelessConnectionState = "Bluetooth unsupported"
        case .resetting:
            bluetoothState = "Resetting"
            wirelessConnectionState = "Bluetooth resetting"
        case .unknown:
            bluetoothState = "Unknown"
            wirelessConnectionState = "Starting"
        @unknown default:
            bluetoothState = "Unknown"
            wirelessConnectionState = "Starting"
        }
    }
}
