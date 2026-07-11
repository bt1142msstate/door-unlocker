import CoreBluetooth
import DoorUnlockerCore
import DoorUnlockerDFU
import DoorUnlockerShared
import Foundation
import os

extension DoorAdminStore {
    func nextWirelessReconnectDelay() -> TimeInterval {
        let index = min(wirelessReconnectAttempt, Self.wirelessReconnectDelays.count - 1)
        wirelessReconnectAttempt += 1
        return Self.wirelessReconnectDelays[index]
    }

    func scheduleWirelessReconnect(after delay: TimeInterval = 1, stateTitle: String = "Reconnecting") {
        wirelessReconnectTask?.cancel()
        wirelessConnectionState = stateTitle
        wirelessReconnectTask = Task { [weak self] in
            let nanoseconds = UInt64(max(0, delay) * 1_000_000_000)
            do { try await Task.sleep(nanoseconds: nanoseconds) } catch { return }
            await MainActor.run {
                guard let self,
                      self.central?.state == .poweredOn,
                      self.canUseWirelessFallback,
                      !self.isFirmwareUpdateRunning,
                      !self.isWirelessGattReady else {
                    return
                }

                self.scanBluetooth()
            }
        }
    }

    func scheduleWirelessIdleDisconnect(after delay: TimeInterval = 1.2) {
        wirelessIdleDisconnectTask?.cancel()
        wirelessIdleDisconnectTask = nil

        guard !hasTrustedMacController else {
            return
        }

        wirelessIdleDisconnectTask = Task { [weak self] in
            let nanoseconds = UInt64(max(0, delay) * 1_000_000_000)
            do { try await Task.sleep(nanoseconds: nanoseconds) } catch { return }
            await MainActor.run {
                guard let self,
                      !self.isConnected,
                      self.canUseWirelessFallback,
                      self.pendingWirelessCommandText == nil,
                      self.pendingWirelessWriteIntents.isEmpty else {
                    return
                }

                self.stopWirelessSession(reason: "Idle")
            }
        }
    }

    func stopWirelessSession(reason: String) {
        if reason == "USB-C active" {
            requeueInterruptedWirelessSettingIfNeeded()
            pendingWirelessCommandText = nil
            pendingWirelessPredictedCommand = nil
            pendingWirelessCommandIntent = nil
        }
        restorePredictedDoorStateIfNeeded()
        wirelessReconnectTask?.cancel()
        wirelessReconnectTask = nil
        wirelessIdleDisconnectTask?.cancel()
        wirelessIdleDisconnectTask = nil
        wirelessKnownPeripheralFallbackTask?.cancel()
        wirelessKnownPeripheralFallbackTask = nil
        wirelessStateSnapshotFallbackTask?.cancel()
        wirelessStateSnapshotFallbackTask = nil
        wirelessFirmwareVersionSnapshotRetryTask?.cancel()
        wirelessFirmwareVersionSnapshotRetryTask = nil
        resetWirelessControlNonceRequest()
        wirelessControlNonceRequestGate.invalidate()
        stopSecureLinkWatchdog()
        stopWirelessDoorCommandTransportRecovery()
        stopWirelessDoorCommandConfirmation()
        stopWirelessScan()
        if let peripheral, peripheral.state == .connected || peripheral.state == .connecting {
            central?.cancelPeripheralConnection(peripheral)
        }
        recordRuntimeTelemetry("wireless_stop", details: reason, once: false)
        pendingWirelessWriteIntents = []
        fastDoorCommandInFlight = nil
        invalidatePreparedFastDoorCommandPayloads(clearNonce: true)
        lastWirelessStateSyncAt = nil
        isWirelessStateNotificationEnabled = false
        resetWirelessLinkAuthentication()
        invalidateControllerFreshness()
        lastControllerActivityAt = nil
        peripheral = nil
        commandCharacteristic = nil
        stateCharacteristic = nil
        pairingCharacteristic = nil
        controlCharacteristic = nil
        wirelessConnectionState = reason
        wirelessPairingState = isConnected ? "USB-C active" : "Unknown"
    }

    func requeueInterruptedWirelessSettingIfNeeded() {
        switch pendingWirelessCommandIntent {
        case .autoLockTimeout(let seconds):
            inFlightAutoLockSeconds = nil
            pendingAutoLockSeconds = seconds
            autoLockStatus = "Waiting for controller"
        case .servoAngles(let angles):
            inFlightServoAngles = nil
            pendingServoAngles = angles
            servoAnglesStatus = "Waiting for controller"
        case .lockName(let name):
            inFlightLockName = nil
            pendingLockName = name
            lockNameStatus = "Waiting for controller"
        default:
            break
        }
    }

    func restorePredictedDoorStateIfNeeded() {
        guard let previousStatus = fastDoorCommandPreviousStatus else { return }
        status = previousStatus
        saveCachedStatus(previousStatus)
        fastDoorCommandPreviousStatus = nil
        fastDoorCommandInFlight = nil
    }

    func prepareWirelessSessionForFirmwareDfu() {
        wirelessReconnectTask?.cancel()
        wirelessReconnectTask = nil
        wirelessIdleDisconnectTask?.cancel()
        wirelessIdleDisconnectTask = nil
        wirelessKnownPeripheralFallbackTask?.cancel()
        wirelessKnownPeripheralFallbackTask = nil
        wirelessStateSnapshotFallbackTask?.cancel()
        wirelessStateSnapshotFallbackTask = nil
        wirelessFirmwareVersionSnapshotRetryTask?.cancel()
        wirelessFirmwareVersionSnapshotRetryTask = nil
        resetWirelessControlNonceRequest()
        wirelessControlNonceRequestGate.invalidate()
        stopSecureLinkWatchdog()
        stopWirelessDoorCommandTransportRecovery()
        stopWirelessDoorCommandConfirmation()
        stopWirelessScan()
        pendingWirelessWriteIntents = []
        fastDoorCommandInFlight = nil
        invalidatePreparedFastDoorCommandPayloads(clearNonce: true)
        pendingWirelessCommandText = nil
        pendingWirelessPredictedCommand = nil
        pendingWirelessCommandIntent = nil
        wirelessConnectionState = "Updating firmware"
    }

    func readStateIfPossible() {
        guard let peripheral, let stateCharacteristic else { return }
        if stateCharacteristic.properties.contains(.read) {
            peripheral.readValue(for: stateCharacteristic)
        }
    }

    func hasPendingDoorCharacteristicDiscovery(on peripheral: CBPeripheral) -> Bool {
        let doorServices = peripheral.services?.filter { $0.uuid == serviceUUID } ?? []
        return doorServices.contains { $0.characteristics == nil }
    }

    func scheduleWirelessStateSnapshotFallbackRead(after delay: TimeInterval = 0.15) {
        wirelessStateSnapshotFallbackTask?.cancel()
        let generation = wirelessStateUpdateGeneration
        wirelessStateSnapshotFallbackTask = Task { [weak self] in
            let nanoseconds = UInt64(max(0, delay) * 1_000_000_000)
            do { try await Task.sleep(nanoseconds: nanoseconds) } catch { return }
            await MainActor.run {
                guard let self,
                      self.wirelessStateUpdateGeneration == generation,
                      self.isWirelessGattReady else {
                    return
                }

                self.wirelessStateSnapshotFallbackTask = nil
                self.readStateIfPossible()
            }
        }
    }
}
