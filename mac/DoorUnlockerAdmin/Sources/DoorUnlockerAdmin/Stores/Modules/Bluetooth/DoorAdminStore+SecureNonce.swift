import CoreBluetooth
import DoorUnlockerCore
import DoorUnlockerDFU
import DoorUnlockerShared
import Foundation
import os

extension DoorAdminStore {
    func enableWirelessControlNotificationsIfPossible(on peripheral: CBPeripheral) {
        guard isCurrentPeripheral(peripheral),
              let controlCharacteristic else {
            return
        }

        if (controlCharacteristic.properties.contains(.notify) || controlCharacteristic.properties.contains(.indicate)),
           !controlCharacteristic.isNotifying {
            peripheral.setNotifyValue(true, for: controlCharacteristic)
        } else if needsFreshSecureNonce {
            scheduleWirelessControlNonceRecoveryIfNeeded()
        }
    }

    func requestWirelessControlNonce() {
        requestWirelessControlNonce(startWatchdog: true)
    }

    func requestWirelessControlNonceWithoutWatchdog() {
        requestWirelessControlNonce(startWatchdog: false)
    }

    func requestWirelessControlNonce(startWatchdog: Bool) {
        guard let peripheral,
              let controlCharacteristic else {
            if startWatchdog {
                startSecureLinkWatchdogIfNeeded()
            }
            return
        }

        if (controlCharacteristic.properties.contains(.notify) || controlCharacteristic.properties.contains(.indicate)),
           !controlCharacteristic.isNotifying {
            peripheral.setNotifyValue(true, for: controlCharacteristic)
            if startWatchdog {
                startSecureLinkWatchdogIfNeeded()
            }
            return
        }

        guard controlCharacteristic.properties.contains(.notify) ||
                controlCharacteristic.properties.contains(.indicate) else {
            lastError = "Controller does not support secure control notifications."
            return
        }

        guard beginWirelessControlNonceRequestIfPossible() else {
            if startWatchdog {
                startSecureLinkWatchdogIfNeeded()
            }
            return
        }

        recordRuntimeTelemetry("secure_nonce_requested", once: false)
        requestNonceViaCommandIfPossible()
        if startWatchdog {
            startSecureLinkWatchdogIfNeeded()
        }
    }

    func beginWirelessControlNonceRequestIfPossible() -> Bool {
        guard !isWirelessControlNonceRequestInFlight else {
            return false
        }

        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastWirelessControlNonceRequestUptime >= Self.wirelessControlNonceRequestMinimumInterval else {
            return false
        }

        lastWirelessControlNonceRequestUptime = now
        isWirelessControlNonceRequestInFlight = true
        wirelessControlNonceRequestGeneration += 1
        scheduleWirelessControlNonceRequestTimeout(generation: wirelessControlNonceRequestGeneration)
        return true
    }

    func resetWirelessControlNonceRequest() {
        isWirelessControlNonceRequestInFlight = false
        wirelessControlNonceRequestGeneration += 1
        wirelessControlNonceRequestTimeoutTask?.cancel()
        wirelessControlNonceRequestTimeoutTask = nil
        wirelessControlNonceRecoveryTask?.cancel()
        wirelessControlNonceRecoveryTask = nil
    }

    func scheduleWirelessControlNonceRequestTimeout(generation: Int) {
        wirelessControlNonceRequestTimeoutTask?.cancel()
        wirelessControlNonceRequestTimeoutTask = Task { [weak self] in
            let delay = UInt64(Self.wirelessControlNonceRequestTimeout * 1_000_000_000)
            try? await Task.sleep(nanoseconds: delay)
            await MainActor.run {
                guard let self,
                      self.wirelessControlNonceRequestGeneration == generation,
                      self.isWirelessControlNonceRequestInFlight else {
                    return
                }

                self.isWirelessControlNonceRequestInFlight = false
                self.wirelessControlNonceRequestTimeoutTask = nil
                if self.needsFreshSecureNonce {
                    self.requestWirelessControlNonceWithoutWatchdog()
                }
            }
        }
    }

    func requestNonceViaCommandIfPossible() {
        guard let peripheral,
              let commandCharacteristic else {
            return
        }

        let payload = Data("nonce".utf8)
        switch DoorReliableWritePolicy.action(
            supportsWriteWithResponse: commandCharacteristic.properties.contains(.write),
            supportsWriteWithoutResponse: commandCharacteristic.properties.contains(.writeWithoutResponse),
            canSendWriteWithoutResponse: peripheral.canSendWriteWithoutResponse
        ) {
        case .writeWithResponse:
            peripheral.writeValue(payload, for: commandCharacteristic, type: .withResponse)
        case .writeWithoutResponse:
            peripheral.writeValue(payload, for: commandCharacteristic, type: .withoutResponse)
        case .unsupported:
            break
        }
    }

    func recoverSecureNonceAfterControllerReject() {
        scheduleWirelessControlNonceRecoveryIfNeeded(
            after: TimeInterval(DoorControllerSettingConfirmationPolicy.controllerIssuedNonceReadDelayNanoseconds) / 1_000_000_000
        )
    }

    func scheduleWirelessControlNonceRecoveryIfNeeded(after delay: TimeInterval = 0.08) {
        guard isWirelessGattReady,
              !isWirelessDoorCommandReady,
              fastCommandNonce == nil,
              (controlCharacteristic?.properties.contains(.notify) == true ||
                controlCharacteristic?.properties.contains(.indicate) == true) else {
            return
        }

        wirelessControlNonceRecoveryTask?.cancel()
        let generation = wirelessControlUpdateGeneration
        wirelessControlNonceRecoveryTask = Task { [weak self] in
            let firstDelay = UInt64(max(0, delay) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: firstDelay)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self,
                      self.wirelessControlUpdateGeneration == generation,
                      self.isWirelessGattReady,
                      !self.isWirelessDoorCommandReady,
                      self.fastCommandNonce == nil else {
                    return
                }

                self.wirelessControlNonceRecoveryTask = nil
                self.requestWirelessControlNonce()
            }
        }
    }
}
