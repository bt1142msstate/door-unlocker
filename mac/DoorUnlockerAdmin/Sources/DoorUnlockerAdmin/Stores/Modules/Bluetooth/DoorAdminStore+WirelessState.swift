import CoreBluetooth
import DoorUnlockerCore
import DoorUnlockerDFU
import DoorUnlockerShared
import Foundation
import os

extension DoorAdminStore {
    func applyWirelessState(_ newState: String) {
        if let applying = ControllerStateParser.settingApplying(from: newState) {
            applyRemoteSettingApplying(kind: applying.kind, value: applying.value)
            updateWirelessPairingState(from: "paired")
            return
        }

        if let controllerLockName = ControllerStateParser.lockName(from: newState, fallback: Self.defaultLockName) {
            applyControllerLockName(controllerLockName)
            updateWirelessPairingState(from: "paired")
            return
        }

        if let controllerAngles = ControllerStateParser.servoAngles(from: newState) {
            var nextStatus = status
            nextStatus.lockAngle = controllerAngles.lockAngle
            nextStatus.unlockAngle = controllerAngles.unlockAngle
            reconcileServoAngles(in: &nextStatus)
            status = nextStatus
            saveCachedStatus(nextStatus)
            updateWirelessPairingState(from: "paired")
            return
        }

        if let lastUnlock = ControllerStateParser.lastUnlockRecord(from: newState) {
            var nextStatus = status
            nextStatus.lastUnlockAt = lastUnlock.unlockedAt
            nextStatus.lastUnlockDeviceIdentifier = lastUnlock.deviceIdentifier
            nextStatus.lastUnlockDeviceName = lastUnlock.deviceName
            status = nextStatus
            saveCachedStatus(nextStatus)
            updateWirelessPairingState(from: "paired")
            return
        }

        if let controllerFirmwareVersion = ControllerStateParser.firmwareVersion(from: newState) {
            var nextStatus = status
            nextStatus.firmwareVersion = controllerFirmwareVersion
            status = nextStatus
            saveCachedStatus(nextStatus)
            wirelessFirmwareVersionSnapshotRetryTask?.cancel()
            wirelessFirmwareVersionSnapshotRetryTask = nil
            postFirmwareVerificationIfNeeded(controllerFirmwareVersion)
            if firmwareUpdateStatus == "Update complete. Verifying..." {
                firmwareUpdateStatus = "Verified \(controllerFirmwareVersion)"
            } else if !isFirmwareUpdateRunning,
                      pendingFirmwareUpdatePackageURL == nil,
                      firmwareUpdateStatus == "Controller entering update mode" {
                firmwareUpdateStatus = "Ready"
            }
            updateWirelessPairingState(from: "paired")
            return
        }

        if let updateState = ControllerStateParser.firmwareUpdateState(from: newState) {
            if updateState == "ota_dfu" {
                firmwareUpdateStatus = "Controller entering update mode"
                beginPendingFirmwareDfuUploadIfNeeded()
            }
            updateWirelessPairingState(from: "paired")
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

        let payload = ControllerStatePayload.parse(newState)
        let isDoorStatePayload = DoorControlPresentationPolicy.isDoorState(payload.state)
        if isDoorStatePayload {
            reconcileWirelessDoorCommands(with: payload.state)
            wirelessStateUpdateGeneration += 1
            wirelessStateSnapshotFallbackTask?.cancel()
            wirelessStateSnapshotFallbackTask = nil
        }

        if payload.state == "pairing_enabled" || payload.state == "pairing_pending" || payload.state == "pairing_locked" {
            var nextStatus = status
            nextStatus.bleState = payload.state
            nextStatus.pairingMode = payload.state == "pairing_enabled" || payload.state == "pairing_pending" ? "enabled" : "locked"
            nextStatus.hasPendingRequest = payload.state == "pairing_pending"
            if payload.state != "pairing_pending" {
                nextStatus.pendingName = nil
            }
            status = statusIncludingLocalUSBConnection(nextStatus)
            saveCachedStatus(status)
            updateWirelessPairingState(from: payload.state)
            message = statusMessage(for: status)
            return
        }

        if payload.state == "timeout_set" {
            if let seconds = payload.remainingSeconds {
                var nextStatus = status
                nextStatus.autoLockSeconds = seconds
                if nextStatus.isUnlocked {
                    nextStatus.autoLockRemainingSeconds = seconds
                    nextStatus.autoLockDeadline = Date().addingTimeInterval(TimeInterval(seconds))
                    hasConfirmedExpiredAutoLockDeadline = false
                }
                reconcileAutoLockSeconds(in: &nextStatus)
                status = nextStatus
                saveCachedStatus(nextStatus)
            }
            updateWirelessPairingState(from: payload.state)
            return
        }

        if payload.state == "paired" {
            clearRemoteSettingApplying()
            var nextStatus = status
            nextStatus.bleState = payload.state
            nextStatus.pairingMode = "locked"
            nextStatus.hasPendingRequest = false
            nextStatus.pendingName = nil
            status = statusIncludingLocalUSBConnection(nextStatus)
            saveCachedStatus(status)
            updateWirelessPairingState(from: payload.state)
            if isConnected, !isBusy {
                Task { [weak self] in
                    try? await self?.loadPairedDevices()
                }
            }
            return
        }

        if payload.state == "rejected", let inFlightControllerSetting {
            failControllerSetting(inFlightControllerSetting, reason: "Controller rejected the setting")
        }

        let deadline = payload.remainingSeconds.map {
            Date().addingTimeInterval(TimeInterval(max(0, $0)))
        }
        var nextStatus = status
        nextStatus.bleState = payload.state
        nextStatus.isUnlocked = payload.state == "unlocked" || payload.state == "unlocking"
        nextStatus.autoLockRemainingSeconds = nextStatus.isUnlocked ? payload.remainingSeconds : nil
        nextStatus.autoLockDeadline = nextStatus.isUnlocked ? deadline : nil
        if payload.state == "rejected" {
            clearRemoteSettingApplying()
        }
        status = nextStatus
        saveCachedStatus(nextStatus)
        if isDoorStatePayload {
            if DoorControlPresentationPolicy.isChangingState(payload.state) {
                scheduleWirelessStateSnapshotFallbackRead(after: 0.25)
            }
        }
        hasConfirmedExpiredAutoLockDeadline = false
        message = statusMessage(for: status)
        updateWirelessPairingState(from: payload.state)
    }
}
