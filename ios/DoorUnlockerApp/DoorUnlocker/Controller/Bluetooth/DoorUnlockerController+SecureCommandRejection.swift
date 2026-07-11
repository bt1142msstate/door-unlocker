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
    func handleFastCommandReject(reason: String) {
        resetControlNonceRequest()
        let rejection = DoorSecureCommandRejection(rawReason: reason)
        invalidatePreparedFastDoorCommandPayloads(clearNonce: true)
        if linkAuthenticationInFlight {
            linkAuthenticationInFlight = false
            hasAuthenticatedCurrentLink = false
        }

        if rejection.invalidatesTrust {
            hasRejectedCurrentSecurePairing = true
        }

        if isFirmwareUpdateRunning {
            pendingFirmwareUpdatePackageURL = nil
            firmwareUpdateEntryCommandSent = false
            firmwareDfuStartFallbackTask?.cancel()
            firmwareDfuStartFallbackTask = nil
            firmwareDfuManager.cancel()
            firmwareUpdateProgress = nil
            firmwareUpdateEstimatedSecondsRemaining = nil
            isFirmwareUpdateRunning = false
            switch rejection.kind {
            case .untrusted:
                firmwareUpdateStatus = "Pair this iPhone before updating firmware"
                lastError = "Pair this iPhone before updating firmware."
            case .staleNonce:
                firmwareUpdateStatus = "Controller asked for a fresh secure command"
                lastError = "Controller asked for a fresh secure command."
            case .busy:
                firmwareUpdateStatus = "Controller is busy"
                lastError = "Controller is busy."
            case .other:
                firmwareUpdateStatus = "Firmware update rejected"
                lastError = "Controller rejected firmware update."
            }
            return
        }

        if handleControllerSettingRejectIfNeeded(rejection) {
            return
        }

        if rejection.requiresFreshNonce,
           let command = optimisticDoorCommand,
           optimisticDoorCommandAttempt < 2 {
            pendingFreshNonceDoorCommand = PendingFreshNonceDoorCommand(
                command: command,
                attempt: optimisticDoorCommandAttempt + 1,
                previousServoState: optimisticDoorPreviousServoState,
                origin: optimisticDoorCommandOrigin ?? .manual
            )
            queuedDoorCommandNonceRequestCount = 0
            lastError = nil
            requestFreshSecureControlNonce()
            return
        }

        if let optimisticDoorCommand {
            let origin = optimisticDoorCommandOrigin
            let restoredState = stableRestoredDoorState()
            clearOptimisticDoorCommand()
            servoState = restoredState
            switch rejection.kind {
            case .busy:
                lastError = "Controller is busy."
            case .staleNonce:
                lastError = "Controller asked for a fresh secure command."
            case .untrusted, .other:
                lastError = "Controller rejected \(optimisticDoorCommand == .unlock ? "unlock" : "lock")."
            }
            if restoredState == "locked" || restoredState == "unlocked" {
                publishWidgetState(restoredState)
            }
            if origin == .proximity {
                endProximityUnlockBackgroundTask()
                if optimisticDoorCommand == .unlock && restoredState != "unlocked" {
                    restoreProximityUnlockAfterInterruptedCommand()
                }
            }
        }

    }

    func clearOptimisticDoorCommand() {
        stopDoorCommandTransportRecovery()
        pendingFreshNonceDoorCommand = nil
        queuedDoorCommandNonceRequestCount = 0
        optimisticDoorCommand = nil
        optimisticDoorCommandOrigin = nil
        optimisticDoorCommandSentAt = nil
        optimisticDoorCommandAttempt = 0
        optimisticDoorCommandAcknowledged = false
        optimisticDoorPreviousServoState = nil
        optimisticDoorCommandSessionGeneration = nil
        doorCommandRecoveryTask?.cancel()
        doorCommandRecoveryTask = nil
    }

    @discardableResult
    func sendPendingFreshNonceDoorCommandIfReady() -> Bool {
        guard let pendingFreshNonceDoorCommand,
              DoorCommandSchedulingPolicy.canDispatchQueuedCommand(
                  isControllerChangingState: isChangingState,
                  hasInFlightCommand: optimisticDoorCommand != nil
              ),
              preparedFastDoorCommandPayloads[pendingFreshNonceDoorCommand.command] != nil else {
            return false
        }

        stopDoorCommandTransportRecovery()
        let retry = pendingFreshNonceDoorCommand
        self.pendingFreshNonceDoorCommand = nil
        queuedDoorCommandNonceRequestCount = 0
        let didSend = sendDoorCommandAttempt(
            pendingFreshNonceDoorCommand.command,
            attempt: pendingFreshNonceDoorCommand.attempt,
            previousServoState: pendingFreshNonceDoorCommand.previousServoState,
            origin: pendingFreshNonceDoorCommand.origin
        )
        if !didSend {
            self.pendingFreshNonceDoorCommand = retry
        }
        return didSend
    }
}
