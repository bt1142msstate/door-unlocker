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
    func applyControllerLockName(_ name: String) {
        if linkAuthenticationInFlight {
            completeLinkAuthentication()
#if DEBUG
            recordStartupTelemetry("door_command_usable", details: "link_authenticated")
#endif
        }
        clearRemoteSettingApplying()
        let sanitizedName = DoorStatusStore.sanitizedLockName(name)
        guard !sanitizedName.isEmpty else { return }

        if sentLockName == sanitizedName {
            lockNameSyncTask?.cancel()
            lockNameSyncTask = nil
            sentLockName = nil
            lastSyncedLockName = sanitizedName
        }
        confirmControllerSetting(.lockName(sanitizedName))
        if pendingLockName == sanitizedName {
            pendingLockName = nil
        }

        let hasNewerLocalIntent = lockName != sanitizedName && (pendingLockName != nil || sentLockName != nil)
        guard !hasNewerLocalIntent else {
            lockNameStatus = controllerSettingPendingStatusTitle
            syncLockNameIfReady()
            return
        }

        if lockName != sanitizedName {
            lockName = sanitizedName
            DoorStatusStore.saveLockName(sanitizedName)
            requestDoorWidgetReload()
        }

        lockNameStatus = "Controller name set"
        syncLockNameIfReady()
    }

    func requestControllerLockNameIfReady() {
        guard isReady,
              fastCommandNonce != nil,
              !isChangingState,
              !hasRequestedControllerLockName,
              pendingLockName == nil,
              sentLockName == nil,
              pendingSystemCommand == nil,
              pendingCommandWriteIntents.isEmpty else { return }

        if writeAuthenticatedCommand("GET_LOCK_NAME", intent: .lockNameRefresh) {
            hasRequestedControllerLockName = true
            lockNameStatus = "Checking controller"
        }
    }

    func requestControllerServoAnglesIfReady() {
        guard isReady,
              fastCommandNonce != nil,
              !isChangingState,
              !hasRequestedControllerServoAngles,
              pendingServoAngles == nil,
              queuedServoAngles == nil,
              sentServoAngles == nil,
              pendingSystemCommand == nil,
              pendingCommandWriteIntents.isEmpty else { return }

        if writeAuthenticatedCommand("GET_ANGLES", intent: .servoAnglesRefresh) {
            hasRequestedControllerServoAngles = true
            servoAnglesStatus = "Checking controller"
        }
    }

    func requestControllerLastUnlockIfReady() {
        guard isReady,
              fastCommandNonce != nil,
              !isChangingState,
              !hasRequestedControllerLastUnlock,
              pendingSystemCommand == nil,
              pendingCommandWriteIntents.isEmpty else { return }

        if writeAuthenticatedCommand("GET_LAST_UNLOCK", intent: .lastUnlockRefresh) {
            hasRequestedControllerLastUnlock = true
        }
    }

    func applyControllerLastUnlock(_ record: LastUnlockRecord) {
        guard let controllerLastUnlockAt = record.unlockedAt else {
            if lastUnlockAt == nil {
                UserDefaults.standard.removeObject(forKey: Self.lastUnlockAtKey)
                UserDefaults.standard.removeObject(forKey: Self.lastUnlockDeviceIdentifierKey)
                UserDefaults.standard.removeObject(forKey: Self.lastUnlockDeviceNameKey)
                lastUnlockDeviceIdentifier = ""
                lastUnlockDeviceName = ""
            }
            return
        }

        applyKnownLastUnlock(
            controllerLastUnlockAt,
            deviceIdentifier: record.deviceIdentifier,
            deviceName: record.deviceName,
            replaceDeviceMetadata: true
        )
    }
}
