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
    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor in
            guard isCurrentPeripheral(peripheral) else { return }

            if let error {
                if (characteristic.uuid != stateUUID && characteristic.uuid != controlUUID) || !isReadNotPermitted(error) {
                    lastError = error.localizedDescription
                }
                return
            }

            guard let data = characteristic.value else { return }
            let rawState = String(data: data, encoding: .utf8) ?? "unknown"
            if characteristic.uuid == controlUUID {
                if let nonce = DoorControllerStateParser.fastCommandNonce(from: rawState) {
                    controlUpdateGeneration += 1
                    controlNonceRecoveryTask?.cancel()
                    controlNonceRecoveryTask = nil
                    applyFastCommandNonce(nonce)
                    return
                }

                if let rejectReason = DoorControllerStateParser.fastCommandRejectReason(from: rawState) {
#if DEBUG
                    recordStartupTelemetry("secure_command_rejected", details: rejectReason, once: false)
#endif
                    controlUpdateGeneration += 1
                    controlNonceRecoveryTask?.cancel()
                    controlNonceRecoveryTask = nil
                    handleFastCommandReject(reason: rejectReason)
                    updatePairingState(
                        from: rejectReason == "unpaired" ? "unpaired" : "paired",
                        authoritative: rejectReason == "unpaired"
                    )
                    return
                }

                if let connections = DoorControllerStateParser.connectedDevices(from: rawState) {
                    connectedDeviceCount = connections.count
                    maximumConnectedDeviceCount = connections.max
                    connectedDevices = connections.devices
                    confirmCurrentDeviceTrustIfListed(in: connections.devices)
                    if pairingState == "Unknown" {
                        promoteKnownControllerPairingIfNeeded()
                    }
                    return
                }

                return
            }

            guard characteristic.uuid == stateUUID else { return }

            if let applying = DoorControllerStateParser.settingApplying(from: rawState) {
                applyRemoteSettingApplying(kind: applying.kind, value: applying.value)
                updatePairingState(from: "paired")
                return
            }

            if let controllerLockName = DoorControllerStateParser.lockName(from: rawState) {
                applyControllerLockName(controllerLockName)
                updatePairingState(from: "paired")
                return
            }

            if let controllerServoAngles = DoorControllerStateParser.servoAngles(from: rawState) {
                applyControllerServoAngles(controllerServoAngles)
                updatePairingState(from: "paired")
                return
            }

            if let controllerLastUnlock = DoorControllerStateParser.lastUnlockRecord(from: rawState) {
                applyControllerLastUnlock(controllerLastUnlock)
                hasRequestedControllerLastUnlock = true
                updatePairingState(from: "paired")
                return
            }

            if let controllerFirmwareVersion = DoorControllerStateParser.firmwareVersion(from: rawState) {
                let expectedFirmwareVersion = UserDefaults.standard.string(
                    forKey: Self.pendingBundledFirmwareUpdateVersionKey
                ) ?? bundledFirmwareVersion
                let didVerifyExpectedFirmware = expectedFirmwareVersion.map {
                    DoorFirmwareUpdatePolicy.decision(
                        installedVersion: controllerFirmwareVersion,
                        bundledVersion: $0
                    ) != .installBundledVersion
                } ?? false
                firmwareVersion = controllerFirmwareVersion
                UserDefaults.standard.set(controllerFirmwareVersion, forKey: Self.cachedFirmwareVersionKey)
                firmwareVersionSnapshotRetryTask?.cancel()
                firmwareVersionSnapshotRetryTask = nil
                clearPendingBundledFirmwareUpdateIfVerified(installedVersion: controllerFirmwareVersion)
#if DEBUG
                handleDebugFirmwareVersionVerification(controllerFirmwareVersion)
#endif
                if isFirmwareUpdateVerifying, didVerifyExpectedFirmware {
                    firmwareUpdateStatus = "Update finished. Controller is on \(controllerFirmwareVersion)."
                    firmwareUpdateProgress = 100
                    firmwareUpdateEstimatedSecondsRemaining = nil
                    lastError = nil
                    finishFirmwareUpdateLiveActivity(version: controllerFirmwareVersion)
                    notifyFirmwareUpdateFinished(version: controllerFirmwareVersion)
                    scheduleFirmwareUpdateSuccessReset()
                }
                evaluateBundledFirmwareAutoUpdate(installedVersion: controllerFirmwareVersion)
                updatePairingState(from: "paired")
                return
            }

            if let updateState = DoorControllerStateParser.firmwareUpdateState(from: rawState) {
                if updateState == "ota_dfu" {
                    firmwareUpdateStatus = "Controller entering update mode"
                    beginPendingFirmwareDfuUploadIfNeeded()
                }
                updatePairingState(from: "paired")
                return
            }

                if let connections = DoorControllerStateParser.connectedDevices(from: rawState) {
                    connectedDeviceCount = connections.count
                    maximumConnectedDeviceCount = connections.max
                    connectedDevices = connections.devices
                    confirmCurrentDeviceTrustIfListed(in: connections.devices)
                    if pairingState == "Unknown" {
                        promoteKnownControllerPairingIfNeeded()
                }
                return
            }

            let parsedState = parseControllerState(rawState)
            if DoorControlPresentationPolicy.isDoorState(parsedState.state) {
                stateUpdateGeneration += 1
                stateSnapshotFallbackTask?.cancel()
                stateSnapshotFallbackTask = nil
            }

            if parsedState.state == "timeout_set" {
                if let seconds = parsedState.remainingSeconds {
                    applyControllerAutoLockTimeout(seconds)
                }
                updatePairingState(from: parsedState.state)
                syncLockNameIfReady()
                syncDeviceDisplayNameIfReady()
                return
            }

            if parsedState.state == "paired" {
                clearRemoteSettingApplying()
                updatePairingState(from: parsedState.state, authoritative: true)
                confirmDeviceDisplayNameSyncIfNeeded()
                syncLockNameIfReady()
                syncDeviceDisplayNameIfReady()
                return
            }

            if shouldIgnoreStaleDoorState(parsedState.state) {
                return
            }

            clearQueuedDoorCommandIfSatisfied(by: parsedState.state)

            if parsedState.state == "rejected" {
                handleControllerRejectedState()
                return
            }

            servoState = parsedState.state
            reconcileOptimisticDoorCommand(with: parsedState.state)
            let isAuthoritativePairingState = [
                "pairing_enabled",
                "pairing_pending",
                "pairing_locked",
                "unpaired"
            ].contains(parsedState.state)
            updatePairingState(from: parsedState.state, authoritative: isAuthoritativePairingState)
            publishWidgetState(parsedState.state, controllerRemainingSeconds: parsedState.remainingSeconds)
            sendPendingSystemCommandIfReady()
            syncLockNameIfReady()
            syncDeviceDisplayNameIfReady()
            runProximityUnlockIfReady()
        }
    }
}
