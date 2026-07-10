import CoreBluetooth
import DoorUnlockerCore
import DoorUnlockerDFU
import DoorUnlockerShared
import Foundation
import os

extension DoorAdminStore {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            guard isCurrentPeripheral(peripheral) else { return }

            if let error {
                wirelessConnectionState = "Service failed"
                lastError = error.localizedDescription
                central?.cancelPeripheralConnection(peripheral)
                scheduleWirelessReconnect(after: nextWirelessReconnectDelay())
                return
            }

            let doorServices = peripheral.services?.filter { $0.uuid == serviceUUID } ?? []
            guard !doorServices.isEmpty else {
                wirelessConnectionState = "Service missing"
                lastError = "Door service not found over Bluetooth."
                central?.cancelPeripheralConnection(peripheral)
                scheduleWirelessReconnect(after: nextWirelessReconnectDelay())
                return
            }

            recordRuntimeTelemetry("services_discovered")
            doorServices.forEach { peripheral.discoverCharacteristics([commandUUID, stateUUID, pairingUUID, controlUUID], for: $0) }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        Task { @MainActor in
            guard isCurrentPeripheral(peripheral) else { return }

            if let error {
                wirelessConnectionState = "Characteristics failed"
                lastError = error.localizedDescription
                central?.cancelPeripheralConnection(peripheral)
                scheduleWirelessReconnect(after: nextWirelessReconnectDelay())
                return
            }

            for characteristic in service.characteristics ?? [] {
                if characteristic.uuid == commandUUID {
                    commandCharacteristic = characteristic
                } else if characteristic.uuid == stateUUID {
                    stateCharacteristic = characteristic
                    if (characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate)),
                       !characteristic.isNotifying {
                        peripheral.setNotifyValue(true, for: characteristic)
                    }
                } else if characteristic.uuid == pairingUUID {
                    pairingCharacteristic = characteristic
                } else if characteristic.uuid == controlUUID {
                    controlCharacteristic = characteristic
                }
            }

            if commandCharacteristic != nil && stateCharacteristic != nil && pairingCharacteristic != nil && controlCharacteristic != nil {
                wirelessKnownPeripheralFallbackTask?.cancel()
                wirelessKnownPeripheralFallbackTask = nil
                markWirelessConnectionObserved()
                wirelessConnectionState = hasTrustedWirelessPairingForSecureCommand ? "Ready" : "USB-C trust needed"
                wirelessReconnectAttempt = 0
                message = hasTrustedWirelessPairingForSecureCommand ? "Wireless ready" : "Connect USB-C to trust this Mac"
                firmwareLog.info("Door GATT ready trusted=\(self.hasTrustedWirelessPairingForSecureCommand, privacy: .public) pendingFirmware=\(self.pendingFirmwareUpdatePackageURL != nil, privacy: .public)")
                recordRuntimeTelemetry("gatt_ready")
                readStateIfPossible()
                scheduleWirelessFirmwareVersionSnapshotRetry()
                enableWirelessControlNotificationsIfPossible(on: peripheral)
                guard hasTrustedWirelessPairingForSecureCommand else {
                    scheduleWirelessIdleDisconnect(after: 0.5)
                    return
                }
                await applyPendingAutoLockSeconds()
                await applyPendingLockName()
                await applyPendingServoAngles()
                sendQueuedWirelessCommand()
                startSecureLinkWatchdogIfNeeded()
                scheduleWirelessIdleDisconnect()
            } else if hasPendingDoorCharacteristicDiscovery(on: peripheral) {
                wirelessConnectionState = "Discovering"
                scheduleKnownPeripheralDiscoveryRetry()
            } else {
                wirelessConnectionState = "Incomplete"
                lastError = "Required Bluetooth characteristics were not found."
                central?.cancelPeripheralConnection(peripheral)
                scheduleWirelessReconnect(after: nextWirelessReconnectDelay())
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor in
            guard isCurrentPeripheral(peripheral) else { return }

            if characteristic.uuid == stateUUID {
                isWirelessStateNotificationEnabled = error == nil && characteristic.isNotifying
                if isWirelessStateNotificationEnabled {
                    recordRuntimeTelemetry("state_notify_enabled")
                    enableWirelessControlNotificationsIfPossible(on: peripheral)
                    scheduleWirelessStateSnapshotFallbackRead()
                    scheduleWirelessFirmwareVersionSnapshotRetry()
                } else if let error {
                    lastError = error.localizedDescription
                }
                return
            }

            if characteristic.uuid == controlUUID {
                if error == nil && characteristic.isNotifying {
                    firmwareLog.info("Control notifications enabled pendingFirmware=\(self.pendingFirmwareUpdatePackageURL != nil, privacy: .public)")
                    recordRuntimeTelemetry("control_notify_enabled")
                    if pendingWirelessCommandText != nil, !isWirelessDoorCommandReady {
                        message = "Preparing secure control"
                    }
                    if needsFreshSecureNonce {
                        requestWirelessControlNonceWithoutWatchdog()
                    } else {
                        scheduleWirelessControlNonceRecoveryIfNeeded(after: 0.06)
                    }
                    startSecureLinkWatchdogIfNeeded()
                    scheduleWirelessStateSnapshotFallbackRead()
                } else if let error {
                    lastError = error.localizedDescription
                }
                return
            }

            if let error {
                lastError = error.localizedDescription
            }
        }
    }
}
