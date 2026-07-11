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
    func scan() {
        guard !isFirmwareUpdateRunning else {
            connectionState = "Updating firmware"
            return
        }

        guard let central else {
            connectionState = "Starting"
            return
        }

        guard central.state == .poweredOn else {
            updateBluetoothAvailabilityState(central.state)
            return
        }

#if DEBUG
        recordStartupTelemetry("scan_requested", details: "state=\(connectionState)")
#endif
        lastError = nil
        reconnectTimer?.invalidate()

        if let peripheral {
            switch peripheral.state {
            case .connected:
                connectionState = hasDiscoveredControllerCharacteristics ? "Ready" : "Discovering"
                if !hasDiscoveredControllerCharacteristics {
                    discoverControllerServices(on: peripheral)
                } else {
                    _ = finishConnectionIfReady()
                    readStateIfPermitted()
                }
                updateProximityUnlockStatus()
                return
            case .connecting:
                connectionState = "Connecting"
                updateProximityUnlockStatus()
                scheduleReconnectCheck(after: reconnectCheckDelay(8))
                return
            case .disconnecting:
                connectionState = "Reconnecting"
                updateProximityUnlockStatus()
                scheduleReconnectCheck(after: reconnectCheckDelay(8))
                return
            case .disconnected:
                break
            @unknown default:
                break
            }
        }

        clearDiscoveredControllerCharacteristics()
        hasRequestedControllerLockName = false
        hasRequestedControllerServoAngles = false
        hasRequestedControllerLastUnlock = false
        pairingState = "Unknown"
        pairingApprovalCode = nil
        updateProximityUnlockStatus()

        if connectToKnownPeripheralIfPossible() {
            return
        }

        startScan()
    }

    func updateBluetoothAvailabilityState(_ state: CBManagerState) {
        switch state {
        case .poweredOn:
            bluetoothState = "On"
        case .poweredOff:
            bluetoothState = "Off"
            connectionState = "Bluetooth off"
        case .unauthorized:
            bluetoothState = "Unauthorized"
            connectionState = "Permission needed"
        case .unsupported:
            bluetoothState = "Unsupported"
            connectionState = "Unsupported"
        case .resetting:
            bluetoothState = "Resetting"
            connectionState = "Resetting"
        case .unknown:
            bluetoothState = "Unknown"
            connectionState = "Starting"
        @unknown default:
            bluetoothState = "Unknown"
            connectionState = "Starting"
        }
    }

    func refreshStateFromController() {
        reconcilePredictedAutoLock()
        if !readStateIfPermitted() {
            requestControllerConnectionIfNeeded()
        }
    }

    func requestControllerConnectionIfNeeded() {
        guard !shouldDeferRefreshScan else { return }
        scan()
    }

    func toggleLock() {
        send(isUnlocked ? .lock : .unlock)
    }

    func performPendingSystemCommand() {
        guard let systemCommand = DoorCommandStore.takePendingCommand() else { return }
        runSystemCommand(systemCommand)
    }

    @discardableResult
    func send(_ command: Command) -> Bool {
        if command == .unlock && requiresUnlockAuthentication {
            Task {
                await authenticateAndSendUnlock()
            }
            return true
        }

        return sendAuthenticated(command)
    }

    @discardableResult
    func sendAuthenticated(_ command: Command, origin: DoorCommandOrigin = .manual) -> Bool {
#if DEBUG
        recordStartupTelemetry("door_command_requested", details: command.rawValue, once: false)
#endif
        cancelPostReadySync()
        return sendDoorCommandAttempt(
            command,
            attempt: 1,
            previousServoState: stableDoorStateForRecovery(),
            origin: origin
        )
    }

    @discardableResult
    func sendDoorCommandAttempt(_ command: Command, attempt: Int, previousServoState: String?, origin: DoorCommandOrigin) -> Bool {
        let commandSentAt = Date()
        let unlockSentAt = command == .unlock ? commandSentAt : nil
        let commandText = command.commandText
        let didWrite = writeAuthenticatedCommand(commandText, intent: .doorCommand(command, unlockSentAt, origin))
        if didWrite {
#if DEBUG
            recordStartupTelemetry("door_command_sent", details: command.rawValue, once: false)
#endif
            optimisticDoorCommand = command
            optimisticDoorCommandOrigin = origin
            optimisticDoorCommandSentAt = commandSentAt
            optimisticDoorCommandAttempt = attempt
            optimisticDoorPreviousServoState = previousServoState
            servoState = command.transitionState
            lastError = nil
            publishWidgetState(servoState, resetAutoLockDeadline: command == .unlock)
            scheduleDoorCommandRecovery(command, sentAt: commandSentAt, attempt: attempt, origin: origin)
        }
        if !didWrite,
           lastError == nil,
           hasTrustedPairingForSecureCommand,
           pendingFreshNonceDoorCommand == nil,
           ((isReady && preparedFastDoorCommandPayloads[command] == nil) || canQueueDoorCommandForKnownController) {
            pendingFreshNonceDoorCommand = PendingFreshNonceDoorCommand(
                command: command,
                attempt: attempt,
                previousServoState: previousServoState,
                origin: origin
            )
            queuedDoorCommandNonceRequestCount = 0
#if DEBUG
            recordStartupTelemetry("door_command_queued_for_nonce", details: command.rawValue, once: false)
#endif
            lastError = nil
            prepareConnectionForQueuedDoorCommand()
            return true
        }
        return didWrite
    }

    func prepareConnectionForQueuedDoorCommand() {
        if isSecureCommandWriteReady {
            if let command = pendingFreshNonceDoorCommand?.command,
               preparedFastDoorCommandPayloads[command] != nil {
                if peripheral?.canSendWriteWithoutResponse == true {
                    _ = sendPendingFreshNonceDoorCommandIfReady()
                } else {
                    scheduleDoorCommandTransportRecovery()
                }
                return
            }

            if let nonce = fastCommandNonce {
                if preparedFastDoorCommandTask == nil {
                    prepareFastDoorCommandPayloads(for: nonce)
                }
                return
            }

            requestFreshSecureControlNonce()
            return
        }

        guard central?.state == .poweredOn else {
            return
        }

        if !connectToKnownPeripheralIfPossible() {
            startScan()
        }
    }
}
