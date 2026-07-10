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
    func clearDiscoveredControllerCharacteristics() {
        knownPairingFallbackTask?.cancel()
        knownPairingFallbackTask = nil
        postReadySyncTask?.cancel()
        postReadySyncTask = nil
        stateSnapshotFallbackTask?.cancel()
        stateSnapshotFallbackTask = nil
        firmwareVersionSnapshotRetryTask?.cancel()
        firmwareVersionSnapshotRetryTask = nil
        controlNonceRecoveryTask?.cancel()
        controlNonceRecoveryTask = nil
        knownPeripheralAssistScanTask?.cancel()
        knownPeripheralAssistScanTask = nil
        commandCharacteristic = nil
        stateCharacteristic = nil
        pairingCharacteristic = nil
        controlCharacteristic = nil
        stopSecureLinkWatchdog()
        stopDoorCommandTransportRecovery()
        stopRSSIMonitoring()
        resetLinkAuthentication()
        pendingCommandWriteIntents.removeAll()
        invalidatePreparedFastDoorCommandPayloads(clearNonce: true)
    }

    func prepareControllerSessionForFirmwareDfu() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        stopControllerScan()
        if let peripheral,
           peripheral.state == .connected || peripheral.state == .connecting {
            central?.cancelPeripheralConnection(peripheral)
        }
        peripheral?.delegate = nil
        peripheral = nil
        clearDiscoveredControllerCharacteristics()
        pendingCommandWriteIntents.removeAll()
        pairingState = "Unknown"
        pairingApprovalCode = nil
        connectionState = "Updating firmware"
        updateProximityUnlockStatus()
    }

    func restoreOrConnect(to restoredPeripheral: CBPeripheral, reason: String) {
        guard !isFirmwareDfuTransportActive,
              let central else { return }

        saveKnownPeripheral(restoredPeripheral)
        if peripheral?.identifier != restoredPeripheral.identifier {
            clearDiscoveredControllerCharacteristics()
        }
        peripheral = restoredPeripheral
        peripheral?.delegate = self
        lastError = nil

        switch restoredPeripheral.state {
        case .connected:
#if DEBUG
            recordStartupTelemetry("restore_connected", details: reason)
#endif
            reconnectTimer?.invalidate()
            connectionState = hasDiscoveredControllerCharacteristics ? reason : "Discovering"
            clearProximityUnlockCandidateIfUnarmed()
            updateProximityUnlockStatus()
            discoverControllerServices(on: restoredPeripheral)
        case .connecting:
#if DEBUG
            recordStartupTelemetry("restore_connecting", details: reason)
#endif
            connectionState = "Reconnecting"
            clearProximityUnlockCandidateIfUnarmed()
            updateProximityUnlockStatus()
            scheduleKnownPeripheralAssistScan()
        case .disconnected, .disconnecting:
#if DEBUG
            recordStartupTelemetry("restore_connect_start", details: reason)
#endif
            connectionState = "Reconnecting"
            clearProximityUnlockCandidateIfUnarmed()
            updateProximityUnlockStatus()
            stopControllerScan()
            central.connect(restoredPeripheral, options: nil)
            scheduleReconnectCheck(after: reconnectCheckDelay(6))
            scheduleKnownPeripheralAssistScan()
        @unknown default:
            connectionState = "Reconnecting"
            updateProximityUnlockStatus()
            stopControllerScan()
            central.connect(restoredPeripheral, options: nil)
            scheduleReconnectCheck(after: reconnectCheckDelay(6))
            scheduleKnownPeripheralAssistScan()
        }
    }

    func discoverControllerServices(on peripheral: CBPeripheral) {
        peripheral.delegate = self

        let cachedDoorServices = peripheral.services?.filter { $0.uuid == serviceUUID } ?? []
        guard !cachedDoorServices.isEmpty else {
#if DEBUG
            recordStartupTelemetry("service_discovery_start")
#endif
            peripheral.discoverServices([serviceUUID])
            scheduleReconnectCheck(after: reconnectCheckDelay(6))
            return
        }

#if DEBUG
        recordStartupTelemetry("cached_service_available")
#endif
        var discoveredAnyCharacteristics = false
        for service in cachedDoorServices {
            if let characteristics = service.characteristics {
                discoveredAnyCharacteristics = true
                applyControllerCharacteristics(characteristics, on: peripheral)
            } else {
                peripheral.discoverCharacteristics([commandUUID, stateUUID, pairingUUID, controlUUID], for: service)
            }
        }

        if discoveredAnyCharacteristics, finishConnectionIfReady() {
            return
        }

        if discoveredAnyCharacteristics {
            cachedDoorServices
                .filter { $0.characteristics == nil || !serviceHasAllRequiredCharacteristics($0) }
                .forEach { peripheral.discoverCharacteristics([commandUUID, stateUUID, pairingUUID, controlUUID], for: $0) }
        }
        scheduleReconnectCheck(after: reconnectCheckDelay(6))
    }

    func applyControllerCharacteristics(_ characteristics: [CBCharacteristic], on peripheral: CBPeripheral) {
        for characteristic in characteristics {
            if characteristic.uuid == commandUUID {
                commandCharacteristic = characteristic
            } else if characteristic.uuid == stateUUID {
                stateCharacteristic = characteristic
                if (characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate)),
                   !characteristic.isNotifying {
                    peripheral.setNotifyValue(true, for: characteristic)
                }
            } else if characteristic.uuid == pairingUUID {
                pairingCharacteristic = characteristic
            } else if characteristic.uuid == controlUUID {
                controlCharacteristic = characteristic
            }
        }

        enableControlNotificationsIfPossible(on: peripheral)
    }

    func enableControlNotificationsIfPossible(on peripheral: CBPeripheral) {
        guard isCurrentPeripheral(peripheral),
              let controlCharacteristic else {
            return
        }

        if (controlCharacteristic.properties.contains(.notify) || controlCharacteristic.properties.contains(.indicate)),
           !controlCharacteristic.isNotifying {
            peripheral.setNotifyValue(true, for: controlCharacteristic)
        } else {
            scheduleControlNonceRecoveryIfNeeded()
        }
    }

    func serviceHasAllRequiredCharacteristics(_ service: CBService) -> Bool {
        let characteristicUUIDs = Set((service.characteristics ?? []).map(\.uuid))
        return characteristicUUIDs.contains(commandUUID)
            && characteristicUUIDs.contains(stateUUID)
            && characteristicUUIDs.contains(pairingUUID)
            && characteristicUUIDs.contains(controlUUID)
    }

    func hasPendingDoorCharacteristicDiscovery(on peripheral: CBPeripheral) -> Bool {
        let doorServices = peripheral.services?.filter { $0.uuid == serviceUUID } ?? []
        return doorServices.contains { $0.characteristics == nil }
    }

    @discardableResult
    func finishConnectionIfReady() -> Bool {
        guard commandCharacteristic != nil,
              stateCharacteristic != nil,
              pairingCharacteristic != nil,
              controlCharacteristic != nil else {
            return false
        }

#if DEBUG
        recordStartupTelemetry("gatt_ready")
#endif
        reconnectTimer?.invalidate()
        knownPeripheralAssistScanTask?.cancel()
        knownPeripheralAssistScanTask = nil
        connectionState = "Ready"
        if proximityUnlockEnabled {
            startRSSIMonitoringIfNeeded()
        }
        _ = promoteKnownControllerPairingIfNeeded()
        requestFreshSecureControlNonce()
        scheduleStateSnapshotFallbackRead()
        scheduleFirmwareVersionSnapshotRetry()
        scheduleKnownPairingFallbackIfNeeded()
        pairFromInviteIfReady()
        if runProximityUnlockIfReady() {
            updateProximityUnlockStatus()
            return true
        }
        sendPendingSystemCommandIfReady()
        updateProximityUnlockStatus()
        return true
    }
}
