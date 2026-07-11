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

extension DoorUnlockerController: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            switch central.state {
            case .poweredOn:
#if DEBUG
                recordStartupTelemetry("bluetooth_powered_on")
#endif
                bluetoothState = "On"
                if isFirmwareDfuTransportActive {
                    stopControllerScan()
                    connectionState = "Updating firmware"
                    updateProximityUnlockStatus()
                    return
                }
                if isSecureCommandWriteReady {
#if DEBUG
                    recordStartupTelemetry("powered_on_ready_skip_scan")
#endif
                    updateProximityUnlockStatus()
                    scheduleStartupCriticalSnapshot()
                    if isReady, !isDoorCommandReady {
#if DEBUG
                        recordStartupTelemetry("powered_on_nonce_nudge")
#endif
                        requestFreshSecureControlNonce()
                    }
                    return
                }
                if proximityUnlockArmedAt != nil {
                    beginProximityUnlockBackgroundTask()
                    accelerateProximityUnlockReconnectIfNeeded()
                } else {
                    scan()
                }
            case .poweredOff, .unauthorized, .unsupported, .resetting, .unknown:
                updateBluetoothAvailabilityState(central.state)
            @unknown default:
                updateBluetoothAvailabilityState(central.state)
            }

            if central.state != .poweredOn {
                clearProximityUnlockCandidate()
                endProximityUnlockBackgroundTask()
            }
            updateProximityUnlockStatus()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        Task { @MainActor in
            self.central = central
            if isFirmwareDfuTransportActive {
                let restoredPeripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
                restoredPeripherals.forEach { central.cancelPeripheralConnection($0) }
                connectionState = "Updating firmware"
                return
            }
            if proximityUnlockArmedAt != nil {
                beginProximityUnlockBackgroundTask()
            }
#if DEBUG
            recordStartupTelemetry("central_restored")
#endif
            connectionState = "Restoring"
            updateProximityUnlockStatus()

            let restoredPeripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
            guard let restoredPeripheral = restoredPeripherals.first(where: { $0.state == .connected || $0.state == .connecting })
                ?? restoredPeripherals.first else {
                return
            }

            restoreOrConnect(to: restoredPeripheral, reason: "Restoring")
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        Task { @MainActor in
            guard !isFirmwareDfuTransportActive else { return }
            if proximityUnlockArmedAt != nil {
                beginProximityUnlockBackgroundTask()
            }
            let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
            deviceName = peripheral.name ?? localName ?? "DoorUnlocker-XIAO-v4"
            lockZoneBluetoothRSSI = RSSI.intValue
#if DEBUG
            recordStartupTelemetry("peripheral_discovered", details: "rssi=\(RSSI.intValue)")
#endif
            connect(to: peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            guard !isFirmwareDfuTransportActive else {
                central.cancelPeripheralConnection(peripheral)
                return
            }
            guard isCurrentPeripheral(peripheral) else {
                central.cancelPeripheralConnection(peripheral)
                return
            }

            if proximityUnlockArmedAt != nil {
                beginProximityUnlockBackgroundTask()
                _ = runProximityUnlockIfReady()
            }
#if DEBUG
            recordStartupTelemetry("peripheral_connected")
#endif
            reconnectTimer?.invalidate()
            completeRestoredConnectionValidation()
            knownPeripheralAssistScanTask?.cancel()
            knownPeripheralAssistScanTask = nil
            stopControllerScan()
            connectionState = "Discovering"
            lastError = nil
            clearProximityUnlockCandidateIfUnarmed()
            updateProximityUnlockStatus()
            peripheral.delegate = self
            saveKnownPeripheral(peripheral)
            discoverControllerServices(on: peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            guard isCurrentPeripheral(peripheral) else { return }

            connectionState = "Disconnected"
            connectedDeviceCount = 0
            connectedDevices = []
            self.peripheral = nil
            lastError = error?.localizedDescription ?? "Connect failed"
            if isKnownOutsideLockZone {
                armProximityUnlockIfOutsideAndDisconnected()
            } else {
                updateProximityUnlockStatus()
            }
            scheduleReconnectCheck(after: Self.fastKnownControllerRetryDelay)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            guard isCurrentPeripheral(peripheral) else { return }

            restoredConnectionValidationTask?.cancel()
            restoredConnectionValidationTask = nil
            restoredConnectionValidationSessionGeneration = nil
            let shouldCheckProximityUnlock = proximityUnlockEnabled && central.state == .poweredOn && hasTrustedPairingForSecureCommand
            connectionState = "Disconnected"
            connectedDeviceCount = 0
            connectedDevices = []
            clearDiscoveredControllerCharacteristics()
            hasRequestedControllerLockName = false
            hasRequestedControllerServoAngles = false
            hasRequestedControllerLastUnlock = false
            pairingState = "Unknown"
            pairingApprovalCode = nil
            if let error {
                lastError = error.localizedDescription
            }
            if isFirmwareDfuTransportActive {
                connectionState = "Updating firmware"
                updateProximityUnlockStatus()
                return
            }
            if shouldCheckProximityUnlock {
                beginProximityUnlockAwayCheck()
                startScan()
            } else if proximityUnlockArmedAt != nil {
                endProximityUnlockBackgroundTask()
                updateProximityUnlockStatus()
                scheduleReconnectCheck(after: Self.fastKnownControllerRetryDelay)
            } else {
                clearProximityUnlockArming()
                updateProximityUnlockStatus()
                scheduleReconnectCheck(after: Self.fastKnownControllerRetryDelay)
            }
        }
    }
}
