import CoreBluetooth
import DoorUnlockerCore
import DoorUnlockerDFU
import DoorUnlockerShared
import Foundation
import os

extension DoorAdminStore {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor in
            guard isCurrentPeripheral(peripheral) else { return }

            if let error {
                lastError = error.localizedDescription
                return
            }

            guard let data = characteristic.value else { return }
            let newState = String(data: data, encoding: .utf8) ?? "unknown"
            if characteristic.uuid == controlUUID {
                if let nonce = ControllerStateParser.fastCommandNonce(from: newState) {
                    wirelessControlUpdateGeneration += 1
                    wirelessControlNonceRecoveryTask?.cancel()
                    wirelessControlNonceRecoveryTask = nil
                    applyFastCommandNonce(nonce)
                    return
                }

                if let rejectReason = ControllerStateParser.fastCommandRejectReason(from: newState) {
                    wirelessControlUpdateGeneration += 1
                    wirelessControlNonceRecoveryTask?.cancel()
                    wirelessControlNonceRecoveryTask = nil
                    handleFastCommandReject(reason: rejectReason)
                    return
                }

                if let connections = ControllerStateParser.connectedDevices(from: newState) {
                    var nextStatus = status
                    nextStatus.connectedCount = connections.count
                    nextStatus.maxConnections = connections.max
                    nextStatus.connectedDevices = connections.devices
                    status = statusIncludingLocalUSBConnection(nextStatus)
                    saveCachedStatus(status)
                    if wirelessPairingState == "Unknown", isWirelessReady, status.pairedCount > 0 {
                        updateWirelessPairingState(from: "paired")
                    }
                    return
                }

                return
            }

            guard characteristic.uuid == stateUUID else { return }
            applyWirelessState(newState)
        }
    }

    nonisolated func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        Task { @MainActor in
            guard isCurrentPeripheral(peripheral), pendingWirelessPredictedCommand != nil else { return }
            sendQueuedWirelessCommand()
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor in
            guard isCurrentPeripheral(peripheral) else { return }

            let commandWriteIntent: WirelessCommandWriteIntent? = {
                guard characteristic.uuid == commandUUID, !pendingWirelessWriteIntents.isEmpty else {
                    return nil
                }
                return pendingWirelessWriteIntents.removeFirst()
            }()

            if let error {
                let isEncryptionError = Self.isBluetoothEncryptionError(error)
                lastError = isEncryptionError ? nil : error.localizedDescription
                if case .firmwareUpdate = commandWriteIntent {
                    firmwareLog.error("OTA DFU entry write failed: \(error.localizedDescription, privacy: .public)")
                }
                if let operation = commandWriteIntent?.controllerSettingOperation {
                    failControllerSetting(operation, reason: error.localizedDescription)
                }
                if case .firmwareUpdate = commandWriteIntent {
                    pendingFirmwareUpdatePackageURL = nil
                    firmwareUpdateEntryCommandSent = false
                    firmwareDfuStartFallbackTask?.cancel()
                    firmwareDfuStartFallbackTask = nil
                    firmwareUpdateStatus = "Firmware update request failed"
                    firmwareUpdateProgress = nil
                    isFirmwareUpdateRunning = false
                }
                if case .linkAuthentication = commandWriteIntent {
                    wirelessLinkAuthenticationInFlight = false
                    hasAuthenticatedCurrentWirelessLink = false
                }
                if case .pairingAdmin = commandWriteIntent {
                    approvalCode = ""
                }
                if characteristic.uuid == pairingUUID {
                    wirelessPairingState = "Pairing locked"
                }
                if isEncryptionError {
                    scheduleWirelessReconnect(
                        after: Self.wirelessEncryptionRecoveryDelay,
                        stateTitle: "Wireless resyncing"
                    )
                } else {
                    scheduleWirelessIdleDisconnect(after: 0.5)
                }
                return
            }

            if characteristic.uuid == pairingUUID {
                if !isWirelessStateNotificationEnabled {
                    readStateIfPossible()
                }
            } else if characteristic.uuid == commandUUID {
                if case .lockName(let name) = commandWriteIntent,
                   inFlightLockName == name {
                    lockNameStatus = "Setting..."
                }
                if case .servoAngles(let angles) = commandWriteIntent,
                   inFlightServoAngles == angles {
                    servoAnglesStatus = "Setting..."
                }
                if case .firmwareUpdate = commandWriteIntent {
                    firmwareLog.info("OTA DFU entry write acknowledged; waiting for controller update mode")
                    firmwareUpdateStatus = "Waiting for controller update mode"
                    scheduleFirmwareDfuStartFallback()
                    return
                }
                if case .linkAuthentication = commandWriteIntent {
                    wirelessLinkAuthenticationInFlight = false
                    hasAuthenticatedCurrentWirelessLink = true
                    recordRuntimeTelemetry("door_command_usable", details: "link_authenticated")
                }
                if case .pairingAdmin = commandWriteIntent {
                    if !isWirelessStateNotificationEnabled {
                        readStateIfPossible()
                    }
                    Task { [weak self] in
                        try? await Task.sleep(for: .milliseconds(350))
                        try? await self?.loadPairedDevices(timeout: 1)
                    }
                }
                if !isWirelessStateNotificationEnabled {
                    readStateIfPossible()
                }
                scheduleWirelessIdleDisconnect()
            }
        }
    }
}
