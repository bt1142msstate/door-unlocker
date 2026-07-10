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
    func sendPendingSystemCommandIfReady() {
        guard isReady, fastCommandNonce != nil else { return }

        if sendQueuedControllerSettingIfReady() {
            return
        }

        guard let command = pendingSystemCommand else { return }
        if command == .toggle, !hasKnownLockState {
            if !readStateIfPermitted() {
                pendingSystemCommand = nil
                toggleLock()
            }
            return
        }

        pendingSystemCommand = nil
        runSystemCommand(command)
    }

    @discardableResult
    func sendQueuedControllerSettingIfReady() -> Bool {
        guard isReady, fastCommandNonce != nil else { return false }

        if let commandText = queuedPairingAdminCommand {
            queuedPairingAdminCommand = nil
            sendPairingAdminCommand(commandText)
            return true
        }

        if let seconds = queuedAutoLockTimeoutSeconds {
            queuedAutoLockTimeoutSeconds = nil
            autoLockSeconds = seconds
            applyAutoLockTimeout()
            return true
        }

        if let angles = queuedServoAngles {
            queuedServoAngles = nil
            servoLockAngle = angles.lockAngle
            servoUnlockAngle = angles.unlockAngle
            pendingServoAngles = angles
            applyServoAngles()
            return true
        }

        return false
    }
}
