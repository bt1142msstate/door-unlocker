import CoreBluetooth
import DoorUnlockerCore
import DoorUnlockerDFU
import DoorUnlockerShared
import Foundation
import os

extension DoorAdminStore: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            switch central.state {
            case .poweredOn:
                bluetoothState = "On"
                recordRuntimeTelemetry("bluetooth_powered_on")
                if canUseWirelessFallback && !isWirelessSessionActive {
                    scanBluetooth()
                } else if isConnected || isUSBConnectInFlight {
                    stopWirelessSession(reason: "USB-C active")
                } else {
                    stopWirelessSession(reason: "Idle")
                }
            case .poweredOff, .unauthorized, .unsupported, .resetting, .unknown:
                updateBluetoothAvailabilityState(central.state)
            @unknown default:
                updateBluetoothAvailabilityState(central.state)
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        Task { @MainActor in
            connect(to: peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            guard isCurrentPeripheral(peripheral) else {
                central.cancelPeripheralConnection(peripheral)
                return
            }

            wirelessKnownPeripheralFallbackTask?.cancel()
            wirelessKnownPeripheralFallbackTask = nil
            wirelessReconnectTask?.cancel()
            wirelessReconnectTask = nil
            saveKnownPeripheral(peripheral)
            markWirelessConnectionObserved()
            wirelessConnectionState = "Discovering"
            recordRuntimeTelemetry("peripheral_connected")
            peripheral.discoverServices([serviceUUID])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            guard isCurrentPeripheral(peripheral) else { return }

            if Self.isBluetoothEncryptionError(error) {
                lastError = nil
                scheduleWirelessReconnect(
                    after: Self.wirelessEncryptionRecoveryDelay,
                    stateTitle: "Wireless resyncing"
                )
                return
            }

            wirelessConnectionState = "Connection failed"
            lastError = error?.localizedDescription
            scheduleWirelessReconnect(after: nextWirelessReconnectDelay())
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        timestamp: CFAbsoluteTime,
        isReconnecting: Bool,
        error: Error?
    ) {
        Task { @MainActor in
            handleWirelessDisconnect(
                central,
                peripheral: peripheral,
                isReconnecting: isReconnecting,
                error: error
            )
        }
    }

    func handleWirelessDisconnect(
        _ central: CBCentralManager,
        peripheral: CBPeripheral,
        isReconnecting: Bool,
        error: Error?
    ) {
        guard isCurrentPeripheral(peripheral) else { return }

        let errorDescription = error?.localizedDescription ?? "none"
        recordRuntimeTelemetry(
            "wireless_disconnect",
            details: "auto=\(isReconnecting) error=\(errorDescription)",
            once: false
        )

        if pendingWirelessCommandText == nil, let command = fastDoorCommandInFlight {
            storePendingWirelessCommand(
                command.commandText,
                predictedDoorCommand: command,
                intent: .doorCommand
            )
        }

        commandCharacteristic = nil
        stateCharacteristic = nil
        pairingCharacteristic = nil
        controlCharacteristic = nil
        isWirelessStateNotificationEnabled = false
        resetWirelessLinkAuthentication()
        resetWirelessControlNonceRequest()
        stopSecureLinkWatchdog()
        stopWirelessDoorCommandTransportRecovery()
        stopWirelessDoorCommandConfirmation()
        fastDoorCommandInFlight = nil
        invalidatePreparedFastDoorCommandPayloads(clearNonce: true)

        if isFirmwareUpdateRunning {
            wirelessConnectionState = "Updating firmware"
            return
        }

        if isReconnecting {
            self.peripheral = peripheral
            wirelessConnectionState = "Reconnecting"
            lastError = nil
            if central.state == .poweredOn && canUseWirelessFallback {
                scheduleWirelessReconnect(after: nextWirelessReconnectDelay())
            }
            return
        }

        self.peripheral = nil
        wirelessConnectionState = "Idle"
        wirelessPairingState = "Unknown"
        if Self.isBluetoothEncryptionError(error) {
            lastError = nil
            if central.state == .poweredOn && canUseWirelessFallback {
                scheduleWirelessReconnect(
                    after: Self.wirelessEncryptionRecoveryDelay,
                    stateTitle: "Wireless resyncing"
                )
            }
            return
        }

        lastError = error?.localizedDescription
        if central.state == .poweredOn && canUseWirelessFallback {
            scheduleWirelessReconnect(after: nextWirelessReconnectDelay())
        }
    }
}
