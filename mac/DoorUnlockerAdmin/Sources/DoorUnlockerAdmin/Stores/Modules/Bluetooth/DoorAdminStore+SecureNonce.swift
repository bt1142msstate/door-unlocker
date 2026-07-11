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
        guard !wirelessControllerNonceHandoffGate.isInFlight else {
            if startWatchdog {
                startSecureLinkWatchdogIfNeeded()
            }
            return
        }
        guard needsFreshSecureNonce else { return }
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
        let now = ProcessInfo.processInfo.systemUptime
        guard let generation = wirelessControlNonceRequestGate.begin(
            at: now,
            minimumInterval: Self.wirelessControlNonceRequestMinimumInterval
        ) else { return false }
        scheduleWirelessControlNonceRequestTimeout(generation: generation)
        return true
    }

    func resetWirelessControlNonceRequest() {
        wirelessControlNonceRequestGate.complete()
        wirelessControlNonceRequestTimeoutTask?.cancel()
        wirelessControlNonceRequestTimeoutTask = nil
        wirelessControlNonceRecoveryTask?.cancel()
        wirelessControlNonceRecoveryTask = nil
    }

    func scheduleWirelessControlNonceRequestTimeout(generation: UInt64) {
        wirelessControlNonceRequestTimeoutTask?.cancel()
        wirelessControlNonceRequestTimeoutTask = Task { [weak self] in
            let delay = UInt64(Self.wirelessControlNonceRequestTimeout * 1_000_000_000)
            do { try await Task.sleep(nanoseconds: delay) } catch { return }
            await MainActor.run {
                guard let self,
                      self.wirelessControlNonceRequestGate.expire(generation: generation) else {
                    return
                }

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
              !wirelessControllerNonceHandoffGate.isInFlight,
              !isApplyingControllerSetting,
              fastDoorCommandInFlight == nil,
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
                      !self.wirelessControllerNonceHandoffGate.isInFlight,
                      !self.isApplyingControllerSetting,
                      self.fastDoorCommandInFlight == nil,
                      !self.isWirelessDoorCommandReady,
                      self.fastCommandNonce == nil else {
                    return
                }

                self.wirelessControlNonceRecoveryTask = nil
                self.requestWirelessControlNonce()
            }
        }
    }

    func beginWirelessControllerNonceHandoff() {
        let now = ProcessInfo.processInfo.systemUptime
        guard let generation = wirelessControllerNonceHandoffGate.begin(at: now, minimumInterval: 0) else {
            return
        }

        wirelessControllerNonceHandoffTimeoutTask?.cancel()
        wirelessControllerNonceHandoffTimeoutTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1.25)) } catch { return }
            await MainActor.run {
                guard let self,
                      self.wirelessControllerNonceHandoffGate.expire(generation: generation) else { return }
                self.wirelessControllerNonceHandoffTimeoutTask = nil
                self.recordRuntimeTelemetry("controller_nonce_handoff_timeout", once: false)
                if self.needsFreshSecureNonce {
                    self.requestWirelessControlNonce()
                }
            }
        }
    }

    func completeWirelessControllerNonceHandoff() {
        wirelessControllerNonceHandoffGate.complete()
        wirelessControllerNonceHandoffTimeoutTask?.cancel()
        wirelessControllerNonceHandoffTimeoutTask = nil
    }

    func resetWirelessControllerNonceHandoff() {
        wirelessControllerNonceHandoffGate.invalidate()
        wirelessControllerNonceHandoffTimeoutTask?.cancel()
        wirelessControllerNonceHandoffTimeoutTask = nil
    }
}
