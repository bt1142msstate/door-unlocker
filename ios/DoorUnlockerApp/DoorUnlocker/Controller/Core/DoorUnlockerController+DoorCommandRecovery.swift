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
    func scheduleDoorCommandRecovery(_ command: Command, sentAt: Date, attempt: Int, origin: DoorCommandOrigin) {
        doorCommandRecoveryTask?.cancel()
        doorCommandRecoveryTask = Task { [weak self] in
            var previousDeadline: Duration = .zero
            for deadline in DoorCommandConfirmationPolicy.fallbackReadDeadlines {
                try? await Task.sleep(for: deadline - previousDeadline)
                previousDeadline = deadline
                guard !Task.isCancelled else { return }

                let shouldContinue = await MainActor.run {
                    guard let self,
                          self.optimisticDoorCommand == command,
                          self.optimisticDoorCommandSentAt == sentAt,
                          self.optimisticDoorCommandAttempt == attempt,
                          self.isChangingState else {
                        return false
                    }
                    _ = self.readStateIfPermitted()
                    if self.optimisticDoorCommandAcknowledged,
                       Date().timeIntervalSince(sentAt) >= Self.acknowledgedDoorCommandSettleDelay {
                        self.settleOptimisticDoorCommand(command)
                        return false
                    }
                    return true
                }

                if !shouldContinue {
                    return
                }
            }

            try? await Task.sleep(for: DoorCommandConfirmationPolicy.failureDeadline - previousDeadline)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard let self,
                      self.optimisticDoorCommand == command,
                      self.optimisticDoorCommandSentAt == sentAt,
                      self.optimisticDoorCommandAttempt == attempt,
                      self.isChangingState else {
                    return
                }

                if self.optimisticDoorCommandAcknowledged {
                    self.settleOptimisticDoorCommand(command)
                    return
                }

                let restoredState = self.stableRestoredDoorState()
#if DEBUG
                self.recordStartupTelemetry(
                    "door_command_confirmation_failed",
                    details: command.rawValue,
                    once: false
                )
#endif
                self.clearOptimisticDoorCommand()
                self.servoState = restoredState
                self.lastError = "Controller did not confirm \(command == .unlock ? "unlock" : "lock")."
                if restoredState == "locked" || restoredState == "unlocked" {
                    self.publishWidgetState(restoredState)
                }
                if origin == .proximity {
                    self.endProximityUnlockBackgroundTask()
                    if command == .unlock && restoredState != "unlocked" {
                        self.restoreProximityUnlockAfterInterruptedCommand()
                    }
                }
            }
        }
    }

    func rejectOptimisticDoorCommand(_ command: Command) {
        let origin = optimisticDoorCommandOrigin
        let restoredState = stableRestoredDoorState()
        clearOptimisticDoorCommand()
        servoState = restoredState
        lastError = "Controller rejected \(command == .unlock ? "unlock" : "lock")."
        updatePairingState(from: restoredState)
        if restoredState == "locked" || restoredState == "unlocked" {
            publishWidgetState(restoredState)
        }
        if origin == .proximity, command == .unlock, restoredState != "unlocked" {
            endProximityUnlockBackgroundTask()
            restoreProximityUnlockAfterInterruptedCommand()
        } else if origin == .proximity {
            endProximityUnlockBackgroundTask()
        }
        _ = readStateIfPermitted()
    }

    func settleOptimisticDoorCommand(_ command: Command) {
        let origin = optimisticDoorCommandOrigin
        if command == .unlock, let optimisticDoorCommandSentAt {
            applyKnownLastUnlock(
                optimisticDoorCommandSentAt,
                deviceName: deviceDisplayName,
                updateLockZone: true
            )
        }

        let finalState = command == .unlock ? "unlocked" : "locked"
        clearOptimisticDoorCommand()
        servoState = finalState
        lastError = nil
        updatePairingState(from: finalState)
        publishWidgetState(finalState, resetAutoLockDeadline: command == .unlock)
        if origin == .proximity {
            endProximityUnlockBackgroundTask()
        }
        _ = readStateIfPermitted()
    }

    func stableDoorStateForRecovery() -> String? {
        if servoState == "locked" || servoState == "unlocked" {
            return servoState
        }

        let snapshotState = DoorStatusStore.load().state
        if snapshotState == "locked" || snapshotState == "unlocked" {
            return snapshotState
        }

        return nil
    }

    func stableRestoredDoorState() -> String {
        if let optimisticDoorPreviousServoState {
            return optimisticDoorPreviousServoState
        }

        return stableDoorStateForRecovery() ?? "unknown"
    }

}
