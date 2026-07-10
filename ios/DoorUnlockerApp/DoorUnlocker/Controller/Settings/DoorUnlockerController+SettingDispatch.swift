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
    func applyAutoLockTimeout() {
        guard isReady else {
            queuedAutoLockTimeoutSeconds = autoLockSeconds
            autoLockStatus = controllerSettingPendingStatusTitle
            requestControllerConnectionIfNeeded()
            return
        }

        let commandText = "SET_TIMEOUT:\(autoLockSeconds)"
        pendingAutoLockTimeoutSeconds = autoLockSeconds
        autoLockStatus = "Setting..."

        guard fastCommandNonce != nil else {
            queuedAutoLockTimeoutSeconds = autoLockSeconds
            autoLockStatus = controllerSettingPendingStatusTitle
            requestFreshSecureControlNonce()
            return
        }

        if writeAuthenticatedCommand(commandText, intent: .autoLockTimeout(autoLockSeconds)) {
            beginControllerSettingConfirmation(.autoLockTimeout(autoLockSeconds))
        } else {
            pendingAutoLockTimeoutSeconds = nil
            autoLockStatus = "Not set"
        }
    }

    func applyServoAngles() {
        let angles = pendingServoAngles ?? ServoAngles(lockAngle: servoLockAngle, unlockAngle: servoUnlockAngle)
        guard DoorControllerPolicy.servoAnglesAreValid(angles) else {
            servoAnglesStatus = "Not set"
            lastError = "Servo angles must stay inside \(Self.minimumServoAngle)-\(Self.maximumServoAngle) degrees."
            return
        }

        guard isReady else {
            queuedServoAngles = angles
            servoAnglesStatus = controllerSettingPendingStatusTitle
            requestControllerConnectionIfNeeded()
            return
        }

        guard fastCommandNonce != nil else {
            queuedServoAngles = angles
            servoAnglesStatus = controllerSettingPendingStatusTitle
            requestFreshSecureControlNonce()
            return
        }

        pendingServoAngles = angles
        sentServoAngles = angles
        servoAnglesStatus = "Setting..."

        if writeAuthenticatedCommand("SET_ANGLES:\(angles.lockAngle),\(angles.unlockAngle)", intent: .servoAngles(angles)) {
            beginControllerSettingConfirmation(.servoAngles(angles))
        } else {
            sentServoAngles = nil
            servoAnglesStatus = "Not set"
        }
    }

    func applyControllerAutoLockTimeout(_ seconds: Int) {
        clearRemoteSettingApplying()
        let confirmedSeconds = DoorControllerPolicy.clampedAutoLockSeconds(seconds)

        if pendingAutoLockTimeoutSeconds == confirmedSeconds {
            pendingAutoLockTimeoutSeconds = nil
        }

        if queuedAutoLockTimeoutSeconds == confirmedSeconds {
            queuedAutoLockTimeoutSeconds = nil
        }
        confirmControllerSetting(.autoLockTimeout(confirmedSeconds))

        let hasNewerLocalIntent = autoLockSeconds != confirmedSeconds
            && (pendingAutoLockTimeoutSeconds != nil || queuedAutoLockTimeoutSeconds != nil)

        guard !hasNewerLocalIntent else {
            autoLockStatus = controllerSettingPendingStatusTitle
            return
        }

        autoLockSeconds = confirmedSeconds
        UserDefaults.standard.set(autoLockSeconds, forKey: Self.autoLockSecondsKey)
        autoLockStatus = "Controller set to \(autoLockSeconds)s"
    }

    func applyControllerServoAngles(_ angles: ServoAngles) {
        clearRemoteSettingApplying()
        let confirmedAngles = DoorControllerPolicy.clampedServoAngles(angles)
        guard DoorControllerPolicy.servoAnglesAreValid(confirmedAngles) else { return }

        if pendingServoAngles == confirmedAngles {
            pendingServoAngles = nil
        }
        if queuedServoAngles == confirmedAngles {
            queuedServoAngles = nil
        }
        if sentServoAngles == confirmedAngles {
            sentServoAngles = nil
        }
        confirmControllerSetting(.servoAngles(confirmedAngles))

        let currentAngles = ServoAngles(lockAngle: servoLockAngle, unlockAngle: servoUnlockAngle)
        let hasNewerLocalIntent = currentAngles != confirmedAngles
            && (pendingServoAngles != nil || queuedServoAngles != nil || sentServoAngles != nil)

        guard !hasNewerLocalIntent else {
            servoAnglesStatus = controllerSettingPendingStatusTitle
            return
        }

        servoLockAngle = confirmedAngles.lockAngle
        servoUnlockAngle = confirmedAngles.unlockAngle
        servoAnglesStatus = "Controller set to \(confirmedAngles.lockAngle)° / \(confirmedAngles.unlockAngle)°"
    }
}
