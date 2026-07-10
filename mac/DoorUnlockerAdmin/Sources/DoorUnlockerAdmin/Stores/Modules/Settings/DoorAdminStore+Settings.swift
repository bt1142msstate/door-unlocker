import CoreBluetooth
import DoorUnlockerCore
import DoorUnlockerDFU
import DoorUnlockerShared
import Foundation
import os

extension DoorAdminStore {
    func refreshAll() {
        guard !isBusy else { return }
        Task { await run("Refreshing") { try await loadControllerState() } }
    }

    func beginLocalSettingApply(_ kind: String) {
        localSettingApplyKind = kind
    }

    func clearLocalSettingApply(_ kind: String) {
        if localSettingApplyKind == kind {
            localSettingApplyKind = nil
        }
    }

    func updateAutoLockSeconds(_ seconds: Int) {
        let clampedSeconds = ControllerStatus.clampedAutoLockSeconds(seconds)
        guard clampedSeconds != status.autoLockSeconds || pendingAutoLockSeconds != nil else { return }

        beginLocalSettingApply("timeout")
        pendingAutoLockSeconds = clampedSeconds
        autoLockStatus = canSendDoorCommand ? "Setting..." : "Waiting for controller"

        var nextStatus = status
        nextStatus.autoLockSeconds = clampedSeconds
        if nextStatus.isUnlocked {
            nextStatus.autoLockRemainingSeconds = clampedSeconds
            nextStatus.autoLockDeadline = Date().addingTimeInterval(TimeInterval(clampedSeconds))
            hasConfirmedExpiredAutoLockDeadline = false
        }
        status = nextStatus

        autoLockApplyTask?.cancel()
        autoLockApplyTask = Task { [weak self] in
            guard await DoorControllerSettingDelay.wait(
                nanoseconds: DoorControllerSettingDelay.inputDebounceNanoseconds
            ) else { return }
            await MainActor.run {
                self?.autoLockApplyTask = nil
            }
            await self?.applyPendingAutoLockSeconds()
        }
    }

    func commitAutoLockSeconds() {
        guard autoLockApplyTask != nil || pendingAutoLockSeconds != nil else { return }
        autoLockApplyTask?.cancel()
        autoLockApplyTask = nil
        Task { [weak self] in
            await self?.applyPendingAutoLockSeconds()
        }
    }

    func updateLockServoAngle(_ angle: Int) {
        updateServoAngles(ServoAngles(lockAngle: angle, unlockAngle: status.unlockAngle))
    }

    func updateUnlockServoAngle(_ angle: Int) {
        updateServoAngles(ServoAngles(lockAngle: status.lockAngle, unlockAngle: angle))
    }

    func resetServoAnglesToDefaults() {
        updateServoAngles(ServoAngles(
            lockAngle: ControllerStatus.defaultLockAngle,
            unlockAngle: ControllerStatus.defaultUnlockAngle
        ))
    }

    func commitServoAngles() {
        guard servoAnglesApplyTask != nil || pendingServoAngles != nil else { return }
        servoAnglesApplyTask?.cancel()
        servoAnglesApplyTask = nil
        Task { [weak self] in
            await self?.applyPendingServoAngles()
        }
    }

    func updateServoAngles(_ requestedAngles: ServoAngles) {
        let clampedAngles = status.clampedServoAngles(requestedAngles)
        guard status.servoAnglesAreValid(clampedAngles) else {
            lastError = "Keep servo angles \(status.servoMinAngleGap) degrees apart and inside \(servoAngleRange.lowerBound)-\(servoAngleRange.upperBound) degrees."
            return
        }
        guard clampedAngles != status.servoAngles || pendingServoAngles != nil else { return }

        beginLocalSettingApply("servo_angles")
        pendingServoAngles = clampedAngles
        servoAnglesStatus = canSendDoorCommand ? "Setting..." : "Waiting for controller"

        var nextStatus = status
        nextStatus.lockAngle = clampedAngles.lockAngle
        nextStatus.unlockAngle = clampedAngles.unlockAngle
        status = nextStatus

        servoAnglesApplyTask?.cancel()
        servoAnglesApplyTask = Task { [weak self] in
            guard await DoorControllerSettingDelay.wait(
                nanoseconds: DoorControllerSettingDelay.inputDebounceNanoseconds
            ) else { return }
            await MainActor.run {
                self?.servoAnglesApplyTask = nil
            }
            await self?.applyPendingServoAngles()
        }
    }

    func lock() {
        sendDoorCommand(.lock)
    }

    func unlock() {
        sendDoorCommand(.unlock)
    }

    func toggleLock() {
        status.isUnlocked ? lock() : unlock()
    }
}
