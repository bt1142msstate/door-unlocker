import DoorUnlockerShared
import Foundation

extension DoorAdminStore {
    func beginControllerSettingConfirmation(_ operation: ControllerSettingOperation) {
        controllerSettingConfirmation.begin(operation)
        controllerSettingConfirmationTask?.cancel()
        controllerSettingConfirmationTask = Task { [weak self] in
            guard await DoorControllerSettingDelay.wait(
                nanoseconds: DoorControllerSettingConfirmationPolicy.stateReadDelayNanoseconds
            ) else { return }
            await MainActor.run {
                guard let self, self.inFlightControllerSetting == operation else { return }
                self.requestWirelessStateNotificationSnapshotReplay()
            }

            guard await DoorControllerSettingDelay.wait(
                nanoseconds: DoorControllerSettingConfirmationPolicy.completionGraceNanoseconds
            ) else { return }
            await MainActor.run {
                self?.finishUnconfirmedControllerSetting(operation)
            }
        }
    }

    func confirmControllerSetting(_ operation: ControllerSettingOperation) {
        guard controllerSettingConfirmation.complete(operation) else { return }
        controllerSettingConfirmationTask?.cancel()
        controllerSettingConfirmationTask = nil
        recordRuntimeTelemetry(
            "controller_setting_confirmed",
            details: String(describing: operation),
            once: false
        )
    }

    func handleControllerSettingRejectIfNeeded(_ rejection: DoorSecureCommandRejection) -> Bool {
        let action = controllerSettingConfirmation.reject(rejection)
        guard action != .none else { return false }
        controllerSettingConfirmationTask?.cancel()
        controllerSettingConfirmationTask = nil
        clearRemoteSettingApplying()

        switch action {
        case .retry(let operation):
            requeueControllerSettingAfterFreshNonce(operation)
            lastError = nil
            recoverSecureNonceAfterControllerReject()
        case .fail(let operation, let reason):
            failControllerSetting(operation, reason: reason)
        case .none:
            break
        }

        return true
    }

    func failControllerSetting(_ operation: ControllerSettingOperation, reason: String) {
        recordRuntimeTelemetry(
            "controller_setting_failed",
            details: "\(String(describing: operation)) reason=\(reason)",
            once: false
        )
        if controllerSettingConfirmation.complete(operation) {
            controllerSettingConfirmationTask?.cancel()
            controllerSettingConfirmationTask = nil
        }
        clearRemoteSettingApplying()

        switch operation {
        case .autoLockTimeout(let seconds):
            if inFlightAutoLockSeconds == seconds {
                inFlightAutoLockSeconds = nil
            }
            if pendingAutoLockSeconds == seconds {
                pendingAutoLockSeconds = nil
            }
            if pendingAutoLockSeconds == nil, inFlightAutoLockSeconds == nil {
                clearLocalSettingApply("timeout")
                autoLockStatus = "Not set"
            }

        case .servoAngles(let angles):
            if inFlightServoAngles == angles {
                inFlightServoAngles = nil
            }
            if pendingServoAngles == angles {
                pendingServoAngles = nil
            }
            if pendingServoAngles == nil, inFlightServoAngles == nil {
                clearLocalSettingApply("servo_angles")
                servoAnglesStatus = "Not set"
            }

        case .lockName(let name):
            if inFlightLockName == name {
                inFlightLockName = nil
            }
            if pendingLockName == name {
                pendingLockName = nil
            }
            if pendingLockName == nil, inFlightLockName == nil {
                clearLocalSettingApply("lock_name")
                lockNameStatus = "Not set"
            }

        case .deviceDisplayName:
            break
        }

        lastError = "\(operation.failureTitle): \(reason)"
    }

    private func finishUnconfirmedControllerSetting(_ operation: ControllerSettingOperation) {
        guard controllerSettingConfirmation.complete(operation) else { return }

        controllerSettingConfirmationTask?.cancel()
        controllerSettingConfirmationTask = nil
        clearRemoteSettingApplying()

        switch operation {
        case .autoLockTimeout(let seconds):
            if inFlightAutoLockSeconds == seconds {
                inFlightAutoLockSeconds = nil
            }
            if pendingAutoLockSeconds == seconds {
                pendingAutoLockSeconds = nil
            }
            if pendingAutoLockSeconds == nil {
                clearLocalSettingApply("timeout")
                autoLockStatus = "Sent to controller"
            }

        case .servoAngles(let angles):
            if inFlightServoAngles == angles {
                inFlightServoAngles = nil
            }
            if pendingServoAngles == angles {
                pendingServoAngles = nil
            }
            if pendingServoAngles == nil {
                clearLocalSettingApply("servo_angles")
                servoAnglesStatus = "Sent to controller"
            }

        case .lockName(let name):
            if inFlightLockName == name {
                inFlightLockName = nil
            }
            if pendingLockName == name {
                pendingLockName = nil
            }
            if pendingLockName == nil {
                clearLocalSettingApply("lock_name")
                lockNameStatus = "Sent to controller"
            }

        case .deviceDisplayName:
            break
        }
    }

    private func requeueControllerSettingAfterFreshNonce(_ operation: ControllerSettingOperation) {
        switch operation {
        case .autoLockTimeout(let seconds):
            let target = pendingAutoLockSeconds ?? seconds
            pendingAutoLockSeconds = nil
            inFlightAutoLockSeconds = target
            beginLocalSettingApply("timeout")
            autoLockStatus = "Retrying..."
            storePendingWirelessCommand(
                "SET_TIMEOUT:\(target)",
                predictedDoorCommand: nil,
                intent: .autoLockTimeout(target)
            )

        case .servoAngles(let angles):
            let target = pendingServoAngles ?? angles
            pendingServoAngles = nil
            inFlightServoAngles = target
            beginLocalSettingApply("servo_angles")
            servoAnglesStatus = "Retrying..."
            storePendingWirelessCommand(
                "SET_ANGLES:\(target.lockAngle),\(target.unlockAngle)",
                predictedDoorCommand: nil,
                intent: .servoAngles(target)
            )

        case .lockName(let name):
            let target = pendingLockName ?? name
            pendingLockName = nil
            inFlightLockName = target
            beginLocalSettingApply("lock_name")
            lockNameStatus = "Retrying..."
            storePendingWirelessCommand(
                "SET_LOCK_NAME:\(target)",
                predictedDoorCommand: nil,
                intent: .lockName(target)
            )

        case .deviceDisplayName:
            break
        }
    }
}
