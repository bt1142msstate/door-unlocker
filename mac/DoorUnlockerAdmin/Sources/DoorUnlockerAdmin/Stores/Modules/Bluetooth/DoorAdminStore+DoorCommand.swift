import CoreBluetooth
import DoorUnlockerCore
import DoorUnlockerDFU
import DoorUnlockerShared
import Foundation
import os

extension DoorAdminStore {
    func sendDoorCommand(_ command: Command) {
        recordRuntimeTelemetry("door_command_requested", details: command.rawValue, once: false)
        if isBusy {
            pendingLocalDoorCommand = command
            message = command == .unlock ? "Unlock queued" : "Lock queued"
            return
        }
        if !isConnected,
           DoorCommandSchedulingPolicy.shouldDeferNewCommand(
               isControllerChangingState: isChangingDoorState,
               hasInFlightCommand: fastDoorCommandInFlight != nil
           ) {
            recordRuntimeTelemetry("door_command_deferred_until_stable", details: command.rawValue, once: false)
            queueWirelessCommand(command.commandText, predictedDoorCommand: command, intent: .doorCommand)
            return
        }
        if DoorControlSurfacePolicy.shouldPreferWirelessDoorCommand(doorControlSurfaceSnapshot) {
            sendWirelessCommandText(command.commandText, predictedDoorCommand: command, intent: .doorCommand)
            return
        }

        if isConnected {
            applyPredictedDoorCommand(command)
            switch command {
            case .lock:
                sendStatusCommand(Self.appLockCommandText(), label: "Lock", timeout: 6, refreshPairsAfterSuccess: false)
            case .unlock:
                sendStatusCommand(Self.appUnlockCommandText(), label: "Unlock", timeout: 6, refreshPairsAfterSuccess: false)
            }
        } else if isWirelessReady {
            sendWirelessCommandText(command.commandText, predictedDoorCommand: command, intent: .doorCommand)
        } else {
            queueWirelessCommand(command.commandText, predictedDoorCommand: command, intent: .doorCommand)
        }
    }

    func applyPredictedDoorCommand(_ command: Command) {
        if fastDoorCommandPreviousStatus == nil {
            fastDoorCommandPreviousStatus = status
        }
        var nextStatus = status
        nextStatus.bleState = command.transitionState
        nextStatus.isUnlocked = command.targetIsUnlocked
        nextStatus.autoLockRemainingSeconds = nil
        nextStatus.autoLockDeadline = nil
        status = nextStatus
        saveCachedStatus(nextStatus)
        hasConfirmedExpiredAutoLockDeadline = false
        message = command == .unlock ? "Unlocking door" : "Locking door"
        scheduleWirelessStateSnapshotFallbackRead(after: 0.25)
    }

    func queueWirelessCommand(
        _ commandText: String,
        predictedDoorCommand: Command? = nil,
        intent: WirelessCommandWriteIntent = .generic
    ) {
        storePendingWirelessCommand(commandText, predictedDoorCommand: predictedDoorCommand, intent: intent)
        if !canQueueWirelessCommandForKnownController {
            wirelessConnectionState = "Connecting on demand"
        }
        guard hasTrustedWirelessPairingForSecureCommand else {
            lastError = "Pair this Mac over USB-C before using wireless commands."
            wirelessPairingState = "USB-C trust needed"
            pendingWirelessCommandText = nil
            pendingWirelessPredictedCommand = nil
            pendingWirelessCommandIntent = nil
            return
        }

        if isWirelessReady {
            sendQueuedWirelessCommand()
        } else {
            scanBluetooth()
        }
    }

    func sendQueuedWirelessCommand() {
        guard let commandText = pendingWirelessCommandText else { return }
        let predictedCommand = pendingWirelessPredictedCommand
        let intent = pendingWirelessCommandIntent ?? .generic
        if case .doorCommand = intent,
           DoorQueuedCommandDispatchPolicy.action(
               queuedDoorCommand: predictedCommand,
               inFlightDoorCommand: fastDoorCommandInFlight
           ) == .discardAlreadyInFlight {
            recordRuntimeTelemetry(
                "duplicate_queued_door_command_discarded",
                details: predictedCommand?.rawValue,
                once: false
            )
            clearPendingWirelessDoorCommandAfterDispatch()
            return
        }
        if case .doorCommand = intent,
           !DoorCommandSchedulingPolicy.canDispatchQueuedCommand(
               isControllerChangingState: isChangingDoorState,
               hasInFlightCommand: fastDoorCommandInFlight != nil
           ) {
            return
        }
        if sendWirelessCommandText(commandText, predictedDoorCommand: predictedCommand, intent: intent) == .sent {
            pendingWirelessCommandText = nil
            pendingWirelessPredictedCommand = nil
            pendingWirelessCommandIntent = nil
        }
    }

    func clearPendingWirelessCommandIfMatchingDoorCommand(_ command: Command) {
        guard case .doorCommand = pendingWirelessCommandIntent,
              pendingWirelessPredictedCommand == command else {
            return
        }

        pendingWirelessCommandText = nil
        pendingWirelessPredictedCommand = nil
        pendingWirelessCommandIntent = nil
        stopWirelessDoorCommandTransportRecovery()
    }

    func clearPendingWirelessDoorCommandAfterDispatch() {
        guard case .doorCommand = pendingWirelessCommandIntent else { return }
        pendingWirelessCommandText = nil
        pendingWirelessPredictedCommand = nil
        pendingWirelessCommandIntent = nil
        stopWirelessDoorCommandTransportRecovery()
    }

    @discardableResult
    func sendWirelessCommandText(
        _ commandText: String,
        predictedDoorCommand: Command? = nil,
        intent: WirelessCommandWriteIntent = .generic
    ) -> WirelessCommandDispatchResult {
        let isIdentityProbe: Bool
        if case .linkAuthentication = intent {
            isIdentityProbe = true
        } else {
            isIdentityProbe = false
        }

        guard let peripheral, let commandCharacteristic else {
            if hasTrustedWirelessPairingForSecureCommand, canUseWirelessFallback {
                queueWirelessCommandForConnectionReadiness(
                    commandText,
                    predictedDoorCommand: predictedDoorCommand,
                    intent: intent
                )
                return .queued
            }
            lastError = "Not connected wirelessly."
            return .failed
        }
        guard hasTrustedWirelessPairingForSecureCommand || isIdentityProbe else {
            lastError = "Pair this Mac over USB-C before using wireless commands."
            wirelessPairingState = "USB-C trust needed"
            pendingWirelessCommandText = nil
            pendingWirelessPredictedCommand = nil
            pendingWirelessCommandIntent = nil
            scheduleWirelessIdleDisconnect(after: 0.5)
            return .failed
        }
        guard isWirelessGattReady else {
            queueWirelessCommandForConnectionReadiness(
                commandText,
                predictedDoorCommand: predictedDoorCommand,
                intent: intent
            )
            return .queued
        }

        if case .doorCommand = intent {
            guard let predictedDoorCommand else {
                lastError = "Door command is missing."
                return .failed
            }
            let fastPayload: DoorCommandAuthenticator.SignedFastCommandPayload
            if hasPreparedFastDoorCommandPayloads,
               let preparedPayload = preparedFastDoorCommandPayloads[predictedDoorCommand] {
                fastPayload = preparedPayload
            } else if hasFastCommandNonce, let nonce = fastCommandNonce {
                do {
                    fastPayload = try DoorCommandAuthenticator.fastCommandPayload(
                        for: predictedDoorCommand,
                        nonce: nonce
                    )
                } catch {
                    lastError = error.localizedDescription
                    return .failed
                }
            } else {
                queueWirelessCommandForSecureNonce(
                    commandText,
                    predictedDoorCommand: predictedDoorCommand,
                    intent: intent
                )
                return .queued
            }

            switch fastDoorCommandWriteAction(
                for: fastPayload.data,
                peripheral: peripheral,
                characteristic: commandCharacteristic
            ) {
            case .sendNow:
                stopWirelessDoorCommandTransportRecovery()
                markFastCommandNonceConsumed()
                invalidatePreparedFastDoorCommandPayloads(clearNonce: true)
                beginWirelessControllerNonceHandoff()
                lastError = nil
                fastDoorCommandInFlight = predictedDoorCommand
                applyPredictedDoorCommand(predictedDoorCommand)
                clearPendingWirelessDoorCommandAfterDispatch()
                peripheral.writeValue(fastPayload.data, for: commandCharacteristic, type: .withoutResponse)
                recordRuntimeTelemetry("wireless_command_sent", details: predictedDoorCommand.rawValue, once: false)
                scheduleWirelessDoorCommandConfirmation(predictedDoorCommand)
                scheduleWirelessIdleDisconnect()
                return .sent
            case .waitForCapacity:
                queueWirelessCommandForTransportCapacity(
                    commandText,
                    predictedDoorCommand: predictedDoorCommand,
                    intent: intent
                )
                return .queued
            case .unsupported:
                lastError = "Secure command is too large for this Bluetooth connection."
                return .failed
            }
        }

        guard hasFastCommandNonce,
              let nonce = fastCommandNonce else {
            queueWirelessCommandForSecureNonce(
                commandText,
                predictedDoorCommand: predictedDoorCommand,
                intent: intent
            )
            return .queued
        }

        do {
            let v3Payload = try DoorCommandAuthenticator.secureCommandPayload(for: commandText, nonce: nonce)
            let payload = v3Payload.data
            guard let writeType = preferredWirelessWriteType(for: payload, intent: intent, peripheral: peripheral, characteristic: commandCharacteristic) else {
                lastError = "Secure command is too large for this Bluetooth connection."
                return .failed
            }

            lastError = nil
            markFastCommandNonceConsumed()
            invalidatePreparedFastDoorCommandPayloads(clearNonce: true)
            beginWirelessControllerNonceHandoff()
            if let predictedDoorCommand {
                applyPredictedDoorCommand(predictedDoorCommand)
            }
            if case .linkAuthentication = intent {
                wirelessLinkAuthenticationInFlight = true
                wirelessLinkAuthenticationAttemptCount += 1
                scheduleWirelessLinkAuthenticationTimeout()
            }
            if writeType == .withResponse {
                pendingWirelessWriteIntents.append(intent)
            }
            peripheral.writeValue(payload, for: commandCharacteristic, type: writeType)
            if let operation = intent.controllerSettingOperation {
                beginControllerSettingConfirmation(operation)
            }
            recordRuntimeTelemetry("wireless_command_sent", details: telemetryCommandLabel(commandText: commandText, predictedDoorCommand: predictedDoorCommand, intent: intent), once: false)
            if writeType == .withoutResponse {
                if case .firmwareUpdate = intent {
                    firmwareLog.info("OTA DFU entry command written without response; waiting for controller update mode")
                    firmwareUpdateStatus = "Waiting for controller update mode"
                    scheduleFirmwareDfuStartFallback()
                } else {
                    scheduleWirelessIdleDisconnect()
                }
            }
            return .sent
        } catch {
            lastError = error.localizedDescription
            return .failed
        }
    }
}
