import CoreBluetooth
import DoorUnlockerCore
import DoorUnlockerDFU
import DoorUnlockerShared
import Foundation
import os

extension DoorAdminStore {
    func startStateSyncLoop() {
        syncTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                await self?.syncControllerStateIfNeeded()
            }
        }
    }

    func updateLockName(_ name: String) {
        let sanitizedName = Self.sanitizedLockName(name)
        guard !sanitizedName.isEmpty else { return }

        if sanitizedName != lockName {
            lockName = sanitizedName
            UserDefaults.standard.set(sanitizedName, forKey: Self.lockNameKey)
        }

        beginLocalSettingApply("lock_name")
        pendingLockName = sanitizedName
        lockNameStatus = canSendDoorCommand ? "Setting..." : "Waiting for controller"
        Task { await applyPendingLockName() }
    }

    static func loadLockName() -> String {
        guard let savedName = UserDefaults.standard.string(forKey: lockNameKey) else {
            return defaultLockName
        }

        let sanitizedName = sanitizedLockName(savedName)
        return sanitizedName.isEmpty ? defaultLockName : sanitizedName
    }

    static func sanitizedLockName(_ name: String) -> String {
        DoorDeviceNameNormalizer.normalized(name, fallback: defaultLockName)
    }

    static func loadCachedStatus() -> ControllerStatus {
        let state: String = {
            switch UserDefaults.standard.string(forKey: cachedBleStateKey) {
            case "unlocked", "unlocking":
                return "unlocked"
            case "locked", "locking":
                return "locked"
            default:
                return "unknown"
            }
        }()

        let autoLockSeconds = UserDefaults.standard.object(forKey: cachedAutoLockSecondsKey) == nil
            ? ControllerStatus().autoLockSeconds
            : UserDefaults.standard.integer(forKey: cachedAutoLockSecondsKey)
        let lockAngle = UserDefaults.standard.object(forKey: cachedLockAngleKey) == nil
            ? ControllerStatus.defaultLockAngle
            : UserDefaults.standard.integer(forKey: cachedLockAngleKey)
        let unlockAngle = UserDefaults.standard.object(forKey: cachedUnlockAngleKey) == nil
            ? ControllerStatus.defaultUnlockAngle
            : UserDefaults.standard.integer(forKey: cachedUnlockAngleKey)
        let pairedCount = UserDefaults.standard.object(forKey: cachedPairedCountKey) == nil
            ? (UserDefaults.standard.bool(forKey: trustedMacControllerKey) ? 1 : 0)
            : UserDefaults.standard.integer(forKey: cachedPairedCountKey)
        let maxPairs = UserDefaults.standard.object(forKey: cachedMaxPairsKey) == nil
            ? ControllerStatus().maxPairs
            : UserDefaults.standard.integer(forKey: cachedMaxPairsKey)
        let maxConnections = UserDefaults.standard.object(forKey: cachedMaxConnectionsKey) == nil
            ? ControllerStatus().maxConnections
            : UserDefaults.standard.integer(forKey: cachedMaxConnectionsKey)
        let cachedAngles = ControllerStatus().clampedServoAngles(ServoAngles(
            lockAngle: lockAngle,
            unlockAngle: unlockAngle
        ))

        return ControllerStatus(
            firmwareVersion: UserDefaults.standard.string(forKey: cachedFirmwareVersionKey) ?? ControllerStatus().firmwareVersion,
            lockName: loadLockName(),
            pairedCount: max(0, pairedCount),
            maxPairs: max(0, maxPairs),
            maxConnections: max(4, maxConnections),
            bleState: state,
            isUnlocked: state == "unlocked",
            autoLockSeconds: ControllerStatus.clampedAutoLockSeconds(autoLockSeconds),
            lockAngle: cachedAngles.lockAngle,
            unlockAngle: cachedAngles.unlockAngle
        )
    }

    func saveCachedStatus(_ status: ControllerStatus) {
        let cacheableStatus = statusRemovingLocalUSBConnection(status)

        switch cacheableStatus.bleState {
        case "locked", "unlocked", "locking", "unlocking":
            UserDefaults.standard.set(cacheableStatus.bleState, forKey: Self.cachedBleStateKey)
        default:
            break
        }

        UserDefaults.standard.set(Self.sanitizedLockName(cacheableStatus.lockName), forKey: Self.lockNameKey)
        UserDefaults.standard.set(cacheableStatus.autoLockSeconds, forKey: Self.cachedAutoLockSecondsKey)
        UserDefaults.standard.set(cacheableStatus.lockAngle, forKey: Self.cachedLockAngleKey)
        UserDefaults.standard.set(cacheableStatus.unlockAngle, forKey: Self.cachedUnlockAngleKey)
        UserDefaults.standard.set(max(0, cacheableStatus.pairedCount), forKey: Self.cachedPairedCountKey)
        UserDefaults.standard.set(max(0, cacheableStatus.maxPairs), forKey: Self.cachedMaxPairsKey)
        UserDefaults.standard.set(max(4, cacheableStatus.maxConnections), forKey: Self.cachedMaxConnectionsKey)
        UserDefaults.standard.set(cacheableStatus.firmwareVersion, forKey: Self.cachedFirmwareVersionKey)
    }

    func applyControllerLockName(_ name: String) {
        if wirelessLinkAuthenticationInFlight {
            completeWirelessLinkAuthentication()
        }
        clearRemoteSettingApplying()
        let sanitizedName = Self.sanitizedLockName(name)
        guard !sanitizedName.isEmpty else { return }
        confirmControllerSetting(.lockName(sanitizedName))

        if inFlightLockName == sanitizedName {
            inFlightLockName = nil
        }
        if pendingLockName == sanitizedName {
            pendingLockName = nil
        }

        let hasNewerLocalIntent = lockName != sanitizedName && (pendingLockName != nil || inFlightLockName != nil)
        guard !hasNewerLocalIntent else {
            lockNameStatus = canSendDoorCommand ? "Setting..." : "Waiting for controller"
            if pendingLockName != nil {
                Task { await applyPendingLockName() }
            }
            return
        }

        lockName = sanitizedName
        UserDefaults.standard.set(sanitizedName, forKey: Self.lockNameKey)
        clearLocalSettingApply("lock_name")
        lockNameStatus = "Controller name set"

        if pendingLockName != nil {
            Task { await applyPendingLockName() }
        }
    }

    func applyPendingLockName() async {
        guard let name = pendingLockName else {
            if inFlightLockName == nil {
                clearLocalSettingApply("lock_name")
            }
            return
        }

        if isBusy && isConnected {
            schedulePendingLockNameRetry()
            return
        }

        if isConnected {
            inFlightLockName = name
            pendingLockName = nil
            lockNameStatus = "Setting..."
            sendStatusCommand("app lock name \(name)", label: "Lock name", timeout: 10, refreshPairsAfterSuccess: false)
            return
        }

        if isWirelessReady {
            inFlightLockName = name
            pendingLockName = nil
            lockNameStatus = "Setting..."
            if sendWirelessCommandText("SET_LOCK_NAME:\(name)", intent: .lockName(name)) == .failed {
                inFlightLockName = nil
                pendingLockName = name
                lockNameStatus = "Not set"
            }
            return
        }

        guard canQueueWirelessCommandForKnownController else {
            lockNameStatus = "Waiting for controller"
            return
        }
        guard pendingWirelessCommandText == nil else {
            lockNameStatus = "Waiting for controller"
            schedulePendingLockNameRetry()
            return
        }
        inFlightLockName = name
        pendingLockName = nil
        lockNameStatus = "Setting..."
        queueWirelessCommand("SET_LOCK_NAME:\(name)", intent: .lockName(name))
    }

    func schedulePendingLockNameRetry() {
        lockNameApplyTask?.cancel()
        lockNameApplyTask = Task { [weak self] in
            guard await DoorControllerSettingDelay.wait(
                nanoseconds: DoorControllerSettingDelay.busyRetryNanoseconds
            ) else { return }
            await MainActor.run {
                self?.lockNameApplyTask = nil
            }
            await self?.applyPendingLockName()
        }
    }
}
