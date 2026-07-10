import Foundation
import DoorUnlockerShared

extension DoorUnlockerController {
    func applyRemoteSettingApplying(kind: String, value: String?) {
        remoteSettingApplyTask?.cancel()
        remoteSettingApplyValue = value
        remoteSettingApplyKind = kind
        remoteSettingApplyTask = Task { [weak self] in
            guard await DoorControllerSettingDelay.wait(
                nanoseconds: DoorControllerSettingConfirmationPolicy.remoteApplyVisibilityNanoseconds
            ) else { return }
            await MainActor.run {
                self?.clearRemoteSettingApplying()
            }
        }
    }

    func clearRemoteSettingApplying() {
        remoteSettingApplyTask?.cancel()
        remoteSettingApplyTask = nil
        remoteSettingApplyKind = nil
        remoteSettingApplyValue = nil
    }

    func beginControllerSettingConfirmation(_ operation: ControllerSettingOperation) {
        controllerSettingConfirmation.begin(operation)
        controllerSettingConfirmationTask?.cancel()
        controllerSettingConfirmationTask = Task { [weak self] in
            guard await DoorControllerSettingDelay.wait(
                nanoseconds: DoorControllerSettingConfirmationPolicy.stateReadDelayNanoseconds
            ) else { return }
            await MainActor.run {
                guard let self, self.inFlightControllerSetting == operation else { return }
                _ = self.readStateIfPermitted()
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
    }

    private func finishUnconfirmedControllerSetting(_ operation: ControllerSettingOperation) {
        guard controllerSettingConfirmation.complete(operation) else { return }

        controllerSettingConfirmationTask?.cancel()
        controllerSettingConfirmationTask = nil
        clearRemoteSettingApplying()

        switch operation {
        case .autoLockTimeout(let seconds):
            if pendingAutoLockTimeoutSeconds == seconds {
                pendingAutoLockTimeoutSeconds = nil
            }
            if queuedAutoLockTimeoutSeconds == seconds {
                queuedAutoLockTimeoutSeconds = nil
            }
            autoLockStatus = "Sent to controller"

        case .servoAngles(let angles):
            if pendingServoAngles == angles {
                pendingServoAngles = nil
            }
            if queuedServoAngles == angles {
                queuedServoAngles = nil
            }
            if sentServoAngles == angles {
                sentServoAngles = nil
            }
            servoAnglesStatus = "Sent to controller"

        case .lockName(let name):
            lockNameSyncTask?.cancel()
            lockNameSyncTask = nil
            if pendingLockName == name {
                pendingLockName = nil
            }
            if sentLockName == name {
                sentLockName = nil
            }
            lockNameStatus = "Sent to controller"

        case .deviceDisplayName(let name):
            deviceDisplayNameSyncTask?.cancel()
            deviceDisplayNameSyncTask = nil
            if pendingDeviceDisplayName == name {
                pendingDeviceDisplayName = nil
            }
            if sentDeviceDisplayName == name {
                sentDeviceDisplayName = nil
            }
            deviceDisplayNameStatus = "Sent to controller"
        }
    }

    @discardableResult
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

    private func requeueControllerSettingAfterFreshNonce(_ operation: ControllerSettingOperation) {
        switch operation {
        case .autoLockTimeout(let seconds):
            pendingAutoLockTimeoutSeconds = nil
            queuedAutoLockTimeoutSeconds = seconds
            autoLockStatus = "Retrying..."
        case .servoAngles(let angles):
            sentServoAngles = nil
            pendingServoAngles = nil
            queuedServoAngles = angles
            servoAnglesStatus = "Retrying..."
        case .lockName(let name):
            sentLockName = nil
            pendingLockName = name
            lockNameStatus = "Retrying..."
        case .deviceDisplayName(let name):
            sentDeviceDisplayName = nil
            pendingDeviceDisplayName = name
            deviceDisplayNameStatus = "Retrying..."
        }
    }

    func failControllerSetting(_ operation: ControllerSettingOperation, reason: String) {
        if controllerSettingConfirmation.complete(operation) {
            controllerSettingConfirmationTask?.cancel()
            controllerSettingConfirmationTask = nil
        }
        clearRemoteSettingApplying()

        switch operation {
        case .autoLockTimeout(let seconds):
            if pendingAutoLockTimeoutSeconds == seconds {
                pendingAutoLockTimeoutSeconds = nil
            }
            if queuedAutoLockTimeoutSeconds == seconds {
                queuedAutoLockTimeoutSeconds = nil
            }
            autoLockStatus = "Not set"
        case .servoAngles(let angles):
            if pendingServoAngles == angles {
                pendingServoAngles = nil
            }
            if queuedServoAngles == angles {
                queuedServoAngles = nil
            }
            if sentServoAngles == angles {
                sentServoAngles = nil
            }
            servoAnglesStatus = "Not set"
        case .lockName(let name):
            lockNameSyncTask?.cancel()
            lockNameSyncTask = nil
            if pendingLockName == name {
                pendingLockName = nil
            }
            if sentLockName == name {
                sentLockName = nil
            }
            lockNameStatus = "Not set"
        case .deviceDisplayName(let name):
            deviceDisplayNameSyncTask?.cancel()
            deviceDisplayNameSyncTask = nil
            if pendingDeviceDisplayName == name {
                pendingDeviceDisplayName = nil
            }
            if sentDeviceDisplayName == name {
                sentDeviceDisplayName = nil
            }
            deviceDisplayNameStatus = "Not set"
        }

        lastError = "\(operation.failureTitle): \(reason)"
    }

    func syncDeviceDisplayNameIfReady() {
        guard pendingDeviceDisplayName != nil || sentDeviceDisplayName != nil else { return }
        let nameToSync = pendingDeviceDisplayName ?? deviceDisplayName
        guard lastSyncedDeviceDisplayName != nameToSync else {
            if sentDeviceDisplayName == nil {
                pendingDeviceDisplayName = nil
                deviceDisplayNameStatus = "Controller name set"
            }
            return
        }

        if let sentName = sentDeviceDisplayName {
            if sentName != nameToSync {
                pendingDeviceDisplayName = nameToSync
                deviceDisplayNameStatus = "Setting..."
            }
            return
        }

        guard isReady else {
            pendingDeviceDisplayName = nameToSync
            deviceDisplayNameStatus = controllerSettingPendingStatusTitle
            requestControllerConnectionIfNeeded()
            return
        }
        guard fastCommandNonce != nil else {
            pendingDeviceDisplayName = nameToSync
            deviceDisplayNameStatus = controllerSettingPendingStatusTitle
            requestFreshSecureControlNonce()
            return
        }

        if writeAuthenticatedCommand("SET_NAME:\(nameToSync)", intent: .deviceDisplayName(nameToSync)) {
            pendingDeviceDisplayName = nil
            sentDeviceDisplayName = nameToSync
            deviceDisplayNameStatus = "Setting..."
            beginControllerSettingConfirmation(.deviceDisplayName(nameToSync))
            scheduleDeviceDisplayNameRetry()
        } else {
            pendingDeviceDisplayName = nameToSync
            deviceDisplayNameStatus = "Not set"
        }
    }

    func confirmDeviceDisplayNameSyncIfNeeded() {
        guard let confirmedName = sentDeviceDisplayName else { return }

        clearRemoteSettingApplying()
        deviceDisplayNameSyncTask?.cancel()
        deviceDisplayNameSyncTask = nil
        sentDeviceDisplayName = nil
        lastSyncedDeviceDisplayName = confirmedName
        confirmControllerSetting(.deviceDisplayName(confirmedName))

        let nextName = pendingDeviceDisplayName
        if nextName == nil || nextName == confirmedName {
            pendingDeviceDisplayName = nil
            deviceDisplayNameStatus = "Controller name set"
        } else {
            deviceDisplayNameStatus = "Setting..."
            syncDeviceDisplayNameIfReady()
        }
    }

    func syncLockNameIfReady() {
        guard pendingLockName != nil || sentLockName != nil else { return }
        let nameToSync = pendingLockName ?? lockName
        guard lastSyncedLockName != nameToSync else {
            if sentLockName == nil {
                pendingLockName = nil
                lockNameStatus = "Controller name set"
            }
            return
        }

        if let sentName = sentLockName {
            if sentName != nameToSync {
                pendingLockName = nameToSync
                lockNameStatus = "Setting..."
            }
            return
        }

        guard isReady else {
            pendingLockName = nameToSync
            lockNameStatus = controllerSettingPendingStatusTitle
            requestControllerConnectionIfNeeded()
            return
        }
        guard fastCommandNonce != nil else {
            pendingLockName = nameToSync
            lockNameStatus = controllerSettingPendingStatusTitle
            requestFreshSecureControlNonce()
            return
        }

        if writeAuthenticatedCommand("SET_LOCK_NAME:\(nameToSync)", intent: .lockName(nameToSync)) {
            pendingLockName = nil
            sentLockName = nameToSync
            lockNameStatus = "Setting..."
            beginControllerSettingConfirmation(.lockName(nameToSync))
            scheduleLockNameRetry()
        } else {
            pendingLockName = nameToSync
            lockNameStatus = "Not set"
        }
    }

    private func scheduleLockNameRetry() {
        lockNameSyncTask?.cancel()
        lockNameSyncTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.lockNameSyncTask = nil
                self?.retryUnconfirmedLockName()
            }
        }
    }

    private func retryUnconfirmedLockName() {
        guard let name = sentLockName else { return }

        sentLockName = nil
        pendingLockName = name
        lockNameStatus = canQueueControllerSettingForKnownController ? "Retrying..." : "Waiting for controller"
        syncLockNameIfReady()
    }

    private func scheduleDeviceDisplayNameRetry() {
        deviceDisplayNameSyncTask?.cancel()
        deviceDisplayNameSyncTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.deviceDisplayNameSyncTask = nil
                self?.retryUnconfirmedDeviceDisplayName()
            }
        }
    }

    private func retryUnconfirmedDeviceDisplayName() {
        guard let name = sentDeviceDisplayName else { return }

        sentDeviceDisplayName = nil
        pendingDeviceDisplayName = name
        deviceDisplayNameStatus = canQueueControllerSettingForKnownController ? "Retrying..." : "Waiting for controller"
        syncDeviceDisplayNameIfReady()
    }
}
