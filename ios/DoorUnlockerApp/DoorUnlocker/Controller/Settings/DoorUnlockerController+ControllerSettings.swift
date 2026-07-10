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
    func updateAutoLockSeconds(_ seconds: Int) {
        let clampedSeconds = DoorControllerPolicy.clampedAutoLockSeconds(seconds)
        guard clampedSeconds != autoLockSeconds else { return }
        guard areSettingsUnlocked else {
            lastError = "Open Settings with Face ID or passcode first"
            return
        }

        autoLockSeconds = clampedSeconds
        UserDefaults.standard.set(autoLockSeconds, forKey: Self.autoLockSecondsKey)
        pendingAutoLockTimeoutSeconds = clampedSeconds
        autoLockStatus = "Release to apply"
    }

    func commitAutoLockSeconds() {
        guard pendingAutoLockTimeoutSeconds != nil || queuedAutoLockTimeoutSeconds != nil else { return }
        applyAutoLockTimeout()
    }

    func updateServoLockAngle(_ angle: Int) {
        updateServoAngles(ServoAngles(lockAngle: angle, unlockAngle: servoUnlockAngle))
    }

    func updateServoUnlockAngle(_ angle: Int) {
        updateServoAngles(ServoAngles(lockAngle: servoLockAngle, unlockAngle: angle))
    }

    func resetServoAnglesToDefaults() {
        updateServoAngles(ServoAngles(
            lockAngle: Self.defaultServoLockAngle,
            unlockAngle: Self.defaultServoUnlockAngle
        ))
        commitServoAngles()
    }

    func commitServoAngles() {
        guard pendingServoAngles != nil || queuedServoAngles != nil else { return }
        applyServoAngles()
    }

    func updateServoAngles(_ requestedAngles: ServoAngles) {
        let angles = DoorControllerPolicy.clampedServoAngles(requestedAngles)
        guard DoorControllerPolicy.servoAnglesAreValid(angles) else {
            lastError = "Keep servo angles inside \(Self.minimumServoAngle)-\(Self.maximumServoAngle) degrees."
            return
        }
        guard angles.lockAngle != servoLockAngle || angles.unlockAngle != servoUnlockAngle || pendingServoAngles != nil else { return }
        guard areSettingsUnlocked else {
            lastError = "Open Settings with Face ID or passcode first"
            return
        }

        servoLockAngle = angles.lockAngle
        servoUnlockAngle = angles.unlockAngle
        pendingServoAngles = angles
        servoAnglesStatus = "Release to apply"
    }

    func updateDeviceDisplayName(_ name: String) {
        let sanitizedName = DoorControllerPolicy.sanitizedName(name, fallback: "Device")
        guard !sanitizedName.isEmpty else { return }
        guard areSettingsUnlocked else {
            lastError = "Open Settings with Face ID or passcode first"
            return
        }

        if sanitizedName != deviceDisplayName {
            deviceDisplayName = sanitizedName
            UserDefaults.standard.set(sanitizedName, forKey: Self.deviceDisplayNameKey)
            lastSyncedDeviceDisplayName = nil
        }

        pendingDeviceDisplayName = sanitizedName
        deviceDisplayNameStatus = controllerSettingPendingStatusTitle
        syncDeviceDisplayNameIfReady()
    }

    func updateLockName(_ name: String) {
        let sanitizedName = DoorStatusStore.sanitizedLockName(name)
        guard !sanitizedName.isEmpty else { return }
        guard areSettingsUnlocked else {
            lastError = "Open Settings with Face ID or passcode first"
            return
        }

        if sanitizedName == lockName && lastSyncedLockName == sanitizedName {
            lockNameStatus = "Controller name set"
            return
        }

        if sanitizedName != lockName {
            lockName = sanitizedName
            DoorStatusStore.saveLockName(sanitizedName)
            requestDoorWidgetReload()
        }

        pendingLockName = sanitizedName
        lockNameStatus = controllerSettingPendingStatusTitle
        syncLockNameIfReady()
    }
}
