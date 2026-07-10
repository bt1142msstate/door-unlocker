import CoreBluetooth
import DoorUnlockerCore
import DoorUnlockerDFU
import DoorUnlockerShared
import Foundation
import os

extension DoorAdminStore {
    static let wirelessConnectOptions: [String: Any] = [
        CBConnectPeripheralOptionEnableAutoReconnect: true
    ]

    func connect(to peripheral: CBPeripheral) {
        guard let central else { return }
        guard canUseWirelessFallback else {
            stopWirelessSession(reason: wirelessStopReason)
            return
        }

        saveKnownPeripheral(peripheral)

        if self.peripheral?.identifier == peripheral.identifier {
            if peripheral.state == .connected {
                if !isWirelessGattReady {
                    peripheral.discoverServices([serviceUUID])
                }
                return
            }
            if peripheral.state == .connecting {
                scheduleKnownPeripheralDiscoveryRetry()
                return
            }
        } else if let currentPeripheral = self.peripheral,
                  currentPeripheral.state == .connecting || currentPeripheral.state == .connected {
            central.cancelPeripheralConnection(currentPeripheral)
        }

        commandCharacteristic = nil
        stateCharacteristic = nil
        pairingCharacteristic = nil
        controlCharacteristic = nil
        isWirelessStateNotificationEnabled = false
        resetWirelessLinkAuthentication()
        resetWirelessControlNonceRequest()
        invalidatePreparedFastDoorCommandPayloads(clearNonce: true)
        wirelessPairingState = "Unknown"
        lastWirelessStateSyncAt = nil
        self.peripheral = peripheral
        self.peripheral?.delegate = self

        if peripheral.state == .connected {
            wirelessConnectionState = isWirelessGattReady ? "Ready" : "Discovering"
            stopWirelessScan()
            peripheral.discoverServices([serviceUUID])
            scheduleKnownPeripheralDiscoveryRetry()
            return
        }

        wirelessConnectionState = "Connecting"
        recordRuntimeTelemetry("connect_start")
        stopWirelessScan()
        central.connect(peripheral, options: Self.wirelessConnectOptions)
        scheduleKnownPeripheralDiscoveryRetry()
    }

    func saveKnownPeripheral(_ peripheral: CBPeripheral) {
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.knownPeripheralIdentifierKey)
    }

    func isCurrentPeripheral(_ peripheral: CBPeripheral) -> Bool {
        self.peripheral?.identifier == peripheral.identifier
    }

    func connectToKnownPeripheralIfPossible() -> Bool {
        guard let central else {
            return false
        }

        if let identifierText = UserDefaults.standard.string(forKey: Self.knownPeripheralIdentifierKey),
           let identifier = UUID(uuidString: identifierText),
           let knownPeripheral = central.retrievePeripherals(withIdentifiers: [identifier]).first,
           knownPeripheral.state != .disconnecting {
            recordRuntimeTelemetry("known_peripheral_retrieved", details: "state=\(knownPeripheral.state.rawValue)")
            restoreOrConnectToKnownPeripheral(knownPeripheral, central: central)
            return true
        }

        let connectedDoorPeripherals = central.retrieveConnectedPeripherals(withServices: [serviceUUID])
        guard let connectedPeripheral = connectedDoorPeripherals.first(where: { $0.state == .connected || $0.state == .connecting })
            ?? connectedDoorPeripherals.first else {
            return false
        }

        recordRuntimeTelemetry("connected_peripheral_retrieved", details: "state=\(connectedPeripheral.state.rawValue)")
        restoreOrConnectToKnownPeripheral(connectedPeripheral, central: central)
        return true
    }

    func restoreOrConnectToKnownPeripheral(_ knownPeripheral: CBPeripheral, central: CBCentralManager) {
        saveKnownPeripheral(knownPeripheral)
        peripheral = knownPeripheral
        peripheral?.delegate = self
        resetWirelessLinkAuthentication()
        wirelessConnectionState = knownPeripheral.state == .connected ? "Discovering" : "Reconnecting"
        stopWirelessScan()

        switch knownPeripheral.state {
        case .connected:
            markWirelessConnectionObserved()
            knownPeripheral.discoverServices([serviceUUID])
        case .connecting:
            break
        case .disconnected:
            central.connect(knownPeripheral, options: Self.wirelessConnectOptions)
        case .disconnecting:
            return
        @unknown default:
            central.connect(knownPeripheral, options: Self.wirelessConnectOptions)
        }

        scheduleKnownPeripheralDiscoveryRetry()
    }

    func scheduleKnownPeripheralDiscoveryRetry() {
        wirelessKnownPeripheralFallbackTask?.cancel()
        wirelessKnownPeripheralFallbackTask = Task { [weak self] in
            let nanoseconds = UInt64(Self.knownPeripheralDiscoveryRetryDelay * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            await MainActor.run {
                guard let self,
                      self.central?.state == .poweredOn,
                      self.canUseWirelessFallback,
                      !self.isWirelessGattReady else {
                    return
                }

                if let peripheral = self.peripheral,
                   peripheral.state == .connected {
                    peripheral.discoverServices([self.serviceUUID])
                    return
                }

                if let peripheral = self.peripheral,
                   peripheral.state == .connecting {
                    self.wirelessConnectionState = "Connecting"
                    self.scheduleKnownPeripheralDiscoveryRetry()
                    return
                }

                self.wirelessConnectionState = "Scanning"
                self.startWirelessScanIfNeeded()
            }
        }
    }

    func scanOptionsForCurrentMode(allowsDuplicates: Bool = false) -> [String: Any] {
        [
            CBCentralManagerScanOptionAllowDuplicatesKey: allowsDuplicates
        ]
    }
}
