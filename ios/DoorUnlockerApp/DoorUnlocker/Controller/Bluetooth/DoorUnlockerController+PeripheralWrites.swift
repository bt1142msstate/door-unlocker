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
    nonisolated func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard error == nil else { return }

        Task { @MainActor in
            guard isCurrentPeripheral(peripheral) else { return }

            lockZoneBluetoothRSSI = RSSI.intValue
            if proximityUnlockArmedAt != nil {
                _ = runProximityUnlockIfReady()
            } else {
                updateProximityUnlockStatus()
            }
        }
    }

    nonisolated func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        Task { @MainActor in
            guard isCurrentPeripheral(peripheral) else { return }
            _ = sendPendingFreshNonceDoorCommandIfReady()
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor in
            guard isCurrentPeripheral(peripheral) else { return }

            let commandWriteIntent: CommandWriteIntent? = {
                guard characteristic.uuid == commandUUID, !pendingCommandWriteIntents.isEmpty else {
                    return nil
                }
                return pendingCommandWriteIntents.removeFirst()
            }()

            if let error {
                if case .autoLockTimeout(let seconds) = commandWriteIntent,
                   pendingAutoLockTimeoutSeconds == seconds {
                    failControllerSetting(.autoLockTimeout(seconds), reason: error.localizedDescription)
                }
                if case .deviceDisplayName(let name) = commandWriteIntent,
                   sentDeviceDisplayName == name {
                    failControllerSetting(.deviceDisplayName(name), reason: error.localizedDescription)
                }
                if case .lockName(let name) = commandWriteIntent,
                   sentLockName == name {
                    failControllerSetting(.lockName(name), reason: error.localizedDescription)
                }
                if case .servoAngles(let angles) = commandWriteIntent,
                   sentServoAngles == angles {
                    failControllerSetting(.servoAngles(angles), reason: error.localizedDescription)
                }
                if case .lockNameRefresh = commandWriteIntent {
                    hasRequestedControllerLockName = false
                    lockNameStatus = "Could not check controller"
                }
                if case .servoAnglesRefresh = commandWriteIntent {
                    hasRequestedControllerServoAngles = false
                    servoAnglesStatus = "Could not check controller"
                }
                if case .lastUnlockRefresh = commandWriteIntent {
                    hasRequestedControllerLastUnlock = false
                }
                if case .firmwareUpdate = commandWriteIntent {
#if DEBUG
                    recordStartupTelemetry("firmware_write_failed", details: error.localizedDescription, once: false)
#endif
                    pendingFirmwareUpdatePackageURL = nil
                    firmwareUpdateEntryCommandSent = false
                    firmwareDfuStartFallbackTask?.cancel()
                    firmwareDfuStartFallbackTask = nil
                    firmwareUpdateStatus = "Firmware update request failed"
                    firmwareUpdateProgress = nil
                    firmwareUpdateEstimatedSecondsRemaining = nil
                    isFirmwareUpdateRunning = false
                    updatePendingFirmwareJournal(phase: .paused, error: error.localizedDescription)
                    scheduleInterruptedFirmwareUpdateRetry()
                }
                if case .linkAuthentication = commandWriteIntent {
                    linkAuthenticationInFlight = false
                    hasAuthenticatedCurrentLink = false
                }
                if case .pairingAdmin(let commandText) = commandWriteIntent {
                    queuedPairingAdminCommand = commandText
                }
                if case .doorCommand(.unlock, _, _) = commandWriteIntent {
                    hasRequestedControllerLastUnlock = false
                }
                if case .doorCommand(let command, _, let origin) = commandWriteIntent {
                    let restoredState = stableRestoredDoorState()
                    clearOptimisticDoorCommand()
                    servoState = restoredState
                    if restoredState == "locked" || restoredState == "unlocked" {
                        publishWidgetState(restoredState)
                    }
                    if command == .unlock, origin == .proximity {
                        restoreProximityUnlockAfterInterruptedCommand()
                    }
                }
                lastError = error.localizedDescription
                if characteristic.uuid == pairingUUID {
                    pairingState = "Pairing locked"
                }
                return
            }

            if case .autoLockTimeout(let seconds) = commandWriteIntent,
               pendingAutoLockTimeoutSeconds == seconds {
                autoLockStatus = "Setting..."
                if isUnlocked {
                    publishWidgetState(servoState, resetAutoLockDeadline: true)
                }
                readStateIfPermitted()
            }

            if case .deviceDisplayName(let name) = commandWriteIntent,
               sentDeviceDisplayName == name {
                deviceDisplayNameStatus = "Setting..."
                readStateIfPermitted()
            }

            if case .lockName(let name) = commandWriteIntent,
               sentLockName == name {
                lockNameStatus = "Setting..."
                readStateIfPermitted()
            }

            if case .servoAngles(let angles) = commandWriteIntent,
               sentServoAngles == angles {
                servoAnglesStatus = "Setting..."
                readStateIfPermitted()
            }

            if case .firmwareUpdate = commandWriteIntent {
#if DEBUG
                recordStartupTelemetry("firmware_write_acknowledged", once: false)
#endif
                firmwareUpdateStatus = "Waiting for controller update mode"
                scheduleFirmwareDfuStartFallback()
                return
            }

            if case .linkAuthentication = commandWriteIntent {
#if DEBUG
                recordStartupTelemetry("link_auth_write_acknowledged")
#endif
            }

            if case .pairingAdmin(let commandText) = commandWriteIntent {
                if commandText.hasPrefix("PAIR_APPROVE:") || commandText == "PAIR_REJECT" {
                    pairingAdminApprovalCode = ""
                }
                readStateIfPermitted()
            }

            if case .lockNameRefresh = commandWriteIntent {
                readStateIfPermitted()
            }

            if case .servoAnglesRefresh = commandWriteIntent {
                readStateIfPermitted()
            }

            if case .lastUnlockRefresh = commandWriteIntent {
                readStateIfPermitted()
            }

            if case .doorCommand = commandWriteIntent {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 120_000_000)
                    _ = self?.readStateIfPermitted()
                }
            }

            if characteristic.uuid == pairingUUID {
                readStateIfPermitted()
            }
        }
    }
}
