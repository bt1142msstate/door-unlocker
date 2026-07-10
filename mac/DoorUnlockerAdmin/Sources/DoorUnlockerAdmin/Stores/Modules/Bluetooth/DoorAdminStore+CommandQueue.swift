import CoreBluetooth
import DoorUnlockerCore
import DoorUnlockerDFU
import DoorUnlockerShared
import Foundation
import os

extension DoorAdminStore {
    func queueWirelessCommandForSecureNonce(
        _ commandText: String,
        predictedDoorCommand: Command?,
        intent: WirelessCommandWriteIntent
    ) {
        storePendingWirelessCommand(commandText, predictedDoorCommand: predictedDoorCommand, intent: intent)

        if let nonce = fastCommandNonce {
            if predictedDoorCommand != nil {
                if preparedFastDoorCommandTask == nil {
                    prepareFastDoorCommandPayloads(for: nonce)
                }
            } else {
                _ = sendQueuedWirelessNonDoorCommandIfReady()
            }
            return
        }

        requestWirelessControlNonce()
    }

    func queueWirelessCommandForConnectionReadiness(
        _ commandText: String,
        predictedDoorCommand: Command?,
        intent: WirelessCommandWriteIntent
    ) {
        storePendingWirelessCommand(commandText, predictedDoorCommand: predictedDoorCommand, intent: intent)
        guard canUseWirelessFallback else { return }
        if let peripheral, peripheral.state == .connected {
            wirelessConnectionState = "Discovering"
            peripheral.discoverServices([serviceUUID])
            scheduleKnownPeripheralDiscoveryRetry()
        } else {
            scanBluetooth()
        }
    }

    func queueWirelessCommandForTransportCapacity(
        _ commandText: String,
        predictedDoorCommand: Command,
        intent: WirelessCommandWriteIntent
    ) {
        storePendingWirelessCommand(commandText, predictedDoorCommand: predictedDoorCommand, intent: intent)
        scheduleWirelessDoorCommandTransportRecovery()
    }

    func storePendingWirelessCommand(
        _ commandText: String,
        predictedDoorCommand: Command?,
        intent: WirelessCommandWriteIntent
    ) {
        pendingWirelessCommandText = commandText
        pendingWirelessPredictedCommand = predictedDoorCommand
        pendingWirelessCommandIntent = intent
        queuedWirelessCommandNonceRequestCount = 0
        lastError = nil
    }
}
