import CoreBluetooth
import DoorUnlockerCore
import DoorUnlockerDFU
import DoorUnlockerShared
import Foundation
import os

extension DoorAdminStore {
    func applyPendingAutoLockSeconds() async {
        guard let seconds = pendingAutoLockSeconds else {
            if inFlightAutoLockSeconds == nil {
                clearLocalSettingApply("timeout")
            }
            return
        }

        if isBusy {
            schedulePendingAutoLockRetry()
            return
        }

        if isConnected {
            inFlightAutoLockSeconds = seconds
            pendingAutoLockSeconds = nil
            autoLockStatus = "Setting..."
            sendStatusCommand("app timeout \(seconds)", label: "Auto-lock", timeout: 4, refreshPairsAfterSuccess: false)
            return
        }

        if isWirelessReady {
            inFlightAutoLockSeconds = seconds
            pendingAutoLockSeconds = nil
            autoLockStatus = "Setting..."
            if sendWirelessCommandText("SET_TIMEOUT:\(seconds)", intent: .autoLockTimeout(seconds)) == .failed {
                inFlightAutoLockSeconds = nil
                pendingAutoLockSeconds = seconds
                autoLockStatus = "Not set"
            }
            return
        }

        inFlightAutoLockSeconds = seconds
        pendingAutoLockSeconds = nil
        autoLockStatus = "Setting..."
        queueWirelessCommand("SET_TIMEOUT:\(seconds)", intent: .autoLockTimeout(seconds))
    }

    func applyPendingServoAngles() async {
        guard let angles = pendingServoAngles else {
            if inFlightServoAngles == nil {
                clearLocalSettingApply("servo_angles")
            }
            return
        }

        if isBusy && isConnected {
            schedulePendingServoAnglesRetry()
            return
        }

        let command = "SET_ANGLES:\(angles.lockAngle),\(angles.unlockAngle)"
        if isConnected {
            inFlightServoAngles = angles
            pendingServoAngles = nil
            servoAnglesStatus = "Setting..."
            sendStatusCommand("app angles \(angles.lockAngle) \(angles.unlockAngle)", label: "Servo angles", timeout: 4, refreshPairsAfterSuccess: false)
            return
        }

        if isWirelessReady {
            inFlightServoAngles = angles
            pendingServoAngles = nil
            servoAnglesStatus = "Setting..."
            if sendWirelessCommandText(command, intent: .servoAngles(angles)) == .failed {
                inFlightServoAngles = nil
                pendingServoAngles = angles
                servoAnglesStatus = "Not set"
            }
            return
        }

        inFlightServoAngles = angles
        pendingServoAngles = nil
        servoAnglesStatus = "Setting..."
        queueWirelessCommand(command, intent: .servoAngles(angles))
    }

    func schedulePendingAutoLockRetry() {
        autoLockApplyTask?.cancel()
        autoLockApplyTask = Task { [weak self] in
            guard await DoorControllerSettingDelay.wait(
                nanoseconds: DoorControllerSettingDelay.busyRetryNanoseconds
            ) else { return }
            await MainActor.run {
                self?.autoLockApplyTask = nil
            }
            await self?.applyPendingAutoLockSeconds()
        }
    }

    func schedulePendingServoAnglesRetry() {
        servoAnglesApplyTask?.cancel()
        servoAnglesApplyTask = Task { [weak self] in
            guard await DoorControllerSettingDelay.wait(
                nanoseconds: DoorControllerSettingDelay.busyRetryNanoseconds
            ) else { return }
            await MainActor.run {
                self?.servoAnglesApplyTask = nil
            }
            await self?.applyPendingServoAngles()
        }
    }

    func applyControllerStatus(_ nextStatus: ControllerStatus) {
        let previousBleState = status.bleState
        var nextStatus = nextStatus
        if let applyingKind = nextStatus.settingApplyingKind {
            applyRemoteSettingApplying(kind: applyingKind, value: nextStatus.settingApplyingValue)
            nextStatus.settingApplyingKind = nil
            nextStatus.settingApplyingValue = nil
        }
        reconcileAutoLockSeconds(in: &nextStatus)
        reconcileServoAngles(in: &nextStatus)
        applyControllerLockName(nextStatus.lockName)
        nextStatus = statusIncludingLocalUSBConnection(nextStatus)

        if !nextStatus.isUnlocked || autoLockDeadlineChanged(from: status.autoLockDeadline, to: nextStatus.autoLockDeadline) {
            hasConfirmedExpiredAutoLockDeadline = false
        }
        status = nextStatus
        saveCachedStatus(nextStatus)
        if previousBleState != nextStatus.bleState {
            recordRuntimeTelemetry("status_state", details: "\(previousBleState) -> \(nextStatus.bleState)", once: false)
        }
    }

    func statusIncludingLocalUSBConnection(_ status: ControllerStatus) -> ControllerStatus {
        guard isConnected || isUSBConnectInFlight else {
            return statusRemovingLocalUSBConnection(status)
        }

        return status.includingLocalConnection(localUSBDevice)
    }

    func statusRemovingLocalUSBConnection(_ status: ControllerStatus) -> ControllerStatus {
        status.removingConnection(handle: Self.localUSBDeviceHandle)
    }

    func reconcileAutoLockSeconds(in nextStatus: inout ControllerStatus) {
        clearRemoteSettingApplying()
        let controllerSeconds = ControllerStatus.clampedAutoLockSeconds(nextStatus.autoLockSeconds)
        confirmControllerSetting(.autoLockTimeout(controllerSeconds))

        if pendingAutoLockSeconds == controllerSeconds {
            pendingAutoLockSeconds = nil
        }

        if inFlightAutoLockSeconds == controllerSeconds {
            inFlightAutoLockSeconds = nil
        }

        let hasNewerLocalIntent = status.autoLockSeconds != controllerSeconds
            && (autoLockApplyTask != nil || pendingAutoLockSeconds != nil || inFlightAutoLockSeconds != nil)

        guard !hasNewerLocalIntent else {
            nextStatus.autoLockSeconds = status.autoLockSeconds
            if status.isUnlocked {
                nextStatus.autoLockRemainingSeconds = status.autoLockRemainingSeconds
                nextStatus.autoLockDeadline = status.autoLockDeadline
            }
            autoLockStatus = canSendDoorCommand ? "Setting..." : "Waiting for controller"
            return
        }

        nextStatus.autoLockSeconds = controllerSeconds
        clearLocalSettingApply("timeout")
        autoLockStatus = "Controller set to \(controllerSeconds)s"
    }

    func reconcileServoAngles(in nextStatus: inout ControllerStatus) {
        clearRemoteSettingApplying()
        let controllerAngles = nextStatus.clampedServoAngles(nextStatus.servoAngles)
        confirmControllerSetting(.servoAngles(controllerAngles))

        if pendingServoAngles == controllerAngles {
            pendingServoAngles = nil
        }

        if inFlightServoAngles == controllerAngles {
            inFlightServoAngles = nil
        }

        let hasNewerLocalIntent = status.servoAngles != controllerAngles
            && (servoAnglesApplyTask != nil || pendingServoAngles != nil || inFlightServoAngles != nil)

        guard !hasNewerLocalIntent else {
            nextStatus.lockAngle = status.lockAngle
            nextStatus.unlockAngle = status.unlockAngle
            servoAnglesStatus = canSendDoorCommand ? "Setting..." : "Waiting for controller"
            return
        }

        nextStatus.lockAngle = controllerAngles.lockAngle
        nextStatus.unlockAngle = controllerAngles.unlockAngle
        clearLocalSettingApply("servo_angles")
        servoAnglesStatus = "Controller set to \(controllerAngles.lockAngle)° / \(controllerAngles.unlockAngle)°"
    }

    func autoLockDeadlineChanged(from oldDeadline: Date?, to newDeadline: Date?) -> Bool {
        switch (oldDeadline, newDeadline) {
        case (.none, .none):
            return false
        case let (.some(oldDeadline), .some(newDeadline)):
            return abs(oldDeadline.timeIntervalSince(newDeadline)) > 1
        default:
            return true
        }
    }
}
