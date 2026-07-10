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
    func startScan() {
        guard !isFirmwareDfuTransportActive,
              central?.state == .poweredOn else { return }

        knownPeripheralAssistScanTask?.cancel()
        knownPeripheralAssistScanTask = nil
        connectionState = "Scanning"
        updateProximityUnlockStatus()
        startControllerScanIfNeeded()
        scheduleReconnectCheck(after: reconnectCheckDelay(5))
    }

    func startControllerScanIfNeeded() {
        guard !isFirmwareDfuTransportActive,
              let central,
              central.state == .poweredOn else { return }

        let allowsDuplicates = proximityUnlockArmedAt != nil
        if central.isScanning, activeScanAllowsDuplicates == allowsDuplicates {
            return
        }

        central.stopScan()
        activeScanAllowsDuplicates = allowsDuplicates
        central.scanForPeripherals(
            withServices: [serviceUUID],
            options: scanOptionsForCurrentMode(allowsDuplicates: allowsDuplicates)
        )
    }

    func stopControllerScan() {
        central?.stopScan()
        activeScanAllowsDuplicates = nil
    }

    func scheduleKnownPeripheralAssistScan(after delay: TimeInterval? = nil) {
        knownPeripheralAssistScanTask?.cancel()
        knownPeripheralAssistScanTask = Task { [weak self] in
            let delay = delay ?? Self.fastKnownControllerRetryDelay
            let nanoseconds = UInt64(max(0, delay) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)

            await MainActor.run {
                guard let self,
                      self.central?.state == .poweredOn,
                      !self.isSecureCommandWriteReady else {
                    return
                }

                guard let peripheral = self.peripheral,
                      peripheral.state == .connecting || peripheral.state == .disconnected else {
                    return
                }

                self.startControllerScanIfNeeded()
                self.knownPeripheralAssistScanTask = nil
            }
        }
    }

    func scanOptionsForCurrentMode(allowsDuplicates: Bool? = nil) -> [String: Any] {
        [
            CBCentralManagerScanOptionAllowDuplicatesKey: allowsDuplicates ?? (proximityUnlockArmedAt != nil)
        ]
    }

    func accelerateProximityUnlockReconnectIfNeeded() {
        guard proximityUnlockEnabled,
              proximityUnlockArmedAt != nil,
              central?.state == .poweredOn,
              !isSecureCommandWriteReady else {
            return
        }

        if !connectToKnownPeripheralIfPossible() {
            startScan()
        }
    }

    func connectToKnownPeripheralIfPossible() -> Bool {
        guard !isFirmwareDfuTransportActive,
              let central else {
            return false
        }

        if let identifierText = UserDefaults.standard.string(forKey: Self.knownPeripheralIdentifierKey),
           let identifier = UUID(uuidString: identifierText),
           let knownPeripheral = central.retrievePeripherals(withIdentifiers: [identifier]).first,
           knownPeripheral.state != .disconnecting {
#if DEBUG
            recordStartupTelemetry("known_peripheral_retrieved", details: "state=\(knownPeripheral.state.rawValue)")
#endif
            restoreOrConnect(to: knownPeripheral, reason: "Known controller")
            return true
        }

        let connectedDoorPeripherals = central.retrieveConnectedPeripherals(withServices: [serviceUUID])
        guard let connectedPeripheral = connectedDoorPeripherals.first(where: { $0.state == .connected || $0.state == .connecting })
            ?? connectedDoorPeripherals.first else {
            return false
        }

#if DEBUG
        recordStartupTelemetry("connected_peripheral_retrieved", details: "state=\(connectedPeripheral.state.rawValue)")
#endif
        restoreOrConnect(to: connectedPeripheral, reason: "Known controller")
        return true
    }

    func connect(to peripheral: CBPeripheral) {
        guard !isFirmwareDfuTransportActive,
              let central else { return }

        saveKnownPeripheral(peripheral)

        if self.peripheral?.identifier == peripheral.identifier {
            if peripheral.state == .connected {
                connectionState = hasDiscoveredControllerCharacteristics ? "Ready" : "Discovering"
                clearProximityUnlockCandidateIfUnarmed()
                updateProximityUnlockStatus()
                if !hasDiscoveredControllerCharacteristics {
                    discoverControllerServices(on: peripheral)
                }
                return
            }

            if peripheral.state == .connecting {
                connectionState = "Connecting"
                clearProximityUnlockCandidateIfUnarmed()
                updateProximityUnlockStatus()
                scheduleReconnectCheck(after: reconnectCheckDelay(5))
                scheduleKnownPeripheralAssistScan()
                return
            }
        } else if let currentPeripheral = self.peripheral,
                  currentPeripheral.state == .connecting || currentPeripheral.state == .connected {
            central.cancelPeripheralConnection(currentPeripheral)
        }

        if self.peripheral?.identifier != peripheral.identifier {
            clearDiscoveredControllerCharacteristics()
        }
        self.peripheral = peripheral
        self.peripheral?.delegate = self

        if peripheral.state == .connected {
#if DEBUG
            recordStartupTelemetry("connect_reused_connected")
#endif
            connectionState = "Discovering"
            clearProximityUnlockCandidateIfUnarmed()
            updateProximityUnlockStatus()
            discoverControllerServices(on: peripheral)
            return
        }

        if peripheral.state == .connecting {
#if DEBUG
            recordStartupTelemetry("connect_reused_connecting")
#endif
            connectionState = "Connecting"
            clearProximityUnlockCandidateIfUnarmed()
            updateProximityUnlockStatus()
            scheduleReconnectCheck(after: reconnectCheckDelay(5))
            scheduleKnownPeripheralAssistScan()
            return
        }

#if DEBUG
        recordStartupTelemetry("connect_start")
#endif
        connectionState = "Connecting"
        clearProximityUnlockCandidateIfUnarmed()
        updateProximityUnlockStatus()
        stopControllerScan()
        central.connect(peripheral, options: nil)
        scheduleReconnectCheck(after: reconnectCheckDelay(6))
        scheduleKnownPeripheralAssistScan()
    }

    func saveKnownPeripheral(_ peripheral: CBPeripheral) {
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.knownPeripheralIdentifierKey)
    }

    func forgetKnownPeripheral(_ peripheral: CBPeripheral) {
        guard UserDefaults.standard.string(forKey: Self.knownPeripheralIdentifierKey) == peripheral.identifier.uuidString else {
            return
        }
        UserDefaults.standard.removeObject(forKey: Self.knownPeripheralIdentifierKey)
    }
}
