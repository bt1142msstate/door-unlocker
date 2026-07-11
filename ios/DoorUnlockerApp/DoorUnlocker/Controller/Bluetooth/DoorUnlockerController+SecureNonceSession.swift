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
    func requestFreshSecureControlNonce() {
        guard !controllerNonceHandoffGate.isInFlight else {
            startSecureLinkWatchdogIfNeeded()
            return
        }
        guard central?.state == .poweredOn else {
            startSecureLinkWatchdogIfNeeded()
            return
        }
        guard let peripheral,
              let controlCharacteristic else {
            startSecureLinkWatchdogIfNeeded()
            return
        }

        if (controlCharacteristic.properties.contains(.notify) || controlCharacteristic.properties.contains(.indicate)),
           !controlCharacteristic.isNotifying {
            peripheral.setNotifyValue(true, for: controlCharacteristic)
            startSecureLinkWatchdogIfNeeded()
            return
        }

        guard controlCharacteristic.properties.contains(.notify) ||
                controlCharacteristic.properties.contains(.indicate) else {
            lastError = "Controller does not support secure control notifications."
            return
        }

        guard beginControlNonceRequestIfPossible() else {
            startSecureLinkWatchdogIfNeeded()
            return
        }
#if DEBUG
        recordStartupTelemetry("secure_nonce_requested")
#endif
        if !requestNonceViaCommandIfPossible() {
            resetControlNonceRequest()
        }
        startSecureLinkWatchdogIfNeeded()
    }

    @discardableResult
    func requestNonceViaCommandIfPossible() -> Bool {
        guard let peripheral,
              let commandCharacteristic else {
            return false
        }

        let payload = Data("nonce".utf8)
        switch DoorReliableWritePolicy.action(
            supportsWriteWithResponse: commandCharacteristic.properties.contains(.write),
            supportsWriteWithoutResponse: commandCharacteristic.properties.contains(.writeWithoutResponse),
            canSendWriteWithoutResponse: peripheral.canSendWriteWithoutResponse
        ) {
        case .writeWithResponse:
            peripheral.writeValue(payload, for: commandCharacteristic, type: .withResponse)
            return true
        case .writeWithoutResponse:
            peripheral.writeValue(payload, for: commandCharacteristic, type: .withoutResponse)
            return true
        case .unsupported:
            return false
        }
    }

    func beginControlNonceRequestIfPossible() -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        guard let generation = controlNonceRequestGate.begin(
            at: now,
            minimumInterval: Self.controlNonceRequestMinimumInterval
        ) else { return false }
        scheduleControlNonceRequestTimeout(generation: generation)
        return true
    }

    func resetControlNonceRequest() {
        controlNonceRequestGate.complete()
        controlNonceRequestTimeoutTask?.cancel()
        controlNonceRequestTimeoutTask = nil
    }

    func scheduleControlNonceRequestTimeout(generation: UInt64) {
        controlNonceRequestTimeoutTask?.cancel()
        controlNonceRequestTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.controlNonceRequestTimeout))
            await MainActor.run {
                guard let self,
                      self.controlNonceRequestGate.expire(generation: generation) else { return }
                self.controlNonceRequestTimeoutTask = nil
                if self.needsFreshSecureNonce {
                    self.requestFreshSecureControlNonce()
                }
            }
        }
    }

    func recoverSecureNonceAfterControllerReject() {
        scheduleControlNonceRecoveryIfNeeded(
            after: .nanoseconds(Int64(DoorControllerSettingConfirmationPolicy.controllerIssuedNonceReadDelayNanoseconds))
        )
    }

    func scheduleControlNonceRecoveryIfNeeded(after delay: Duration = .milliseconds(80)) {
        guard isReady,
              !controllerNonceHandoffGate.isInFlight,
              inFlightControllerSetting == nil,
              remoteSettingApplyKind == nil,
              optimisticDoorCommand == nil,
              !isDoorCommandReady,
              fastCommandNonce == nil,
              (controlCharacteristic?.properties.contains(.notify) == true ||
                controlCharacteristic?.properties.contains(.indicate) == true) else {
            return
        }

        controlNonceRecoveryTask?.cancel()
        let generation = controlUpdateGeneration
        controlNonceRecoveryTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self,
                      self.controlUpdateGeneration == generation,
                      self.isReady,
                      !self.controllerNonceHandoffGate.isInFlight,
                      self.inFlightControllerSetting == nil,
                      self.remoteSettingApplyKind == nil,
                      self.optimisticDoorCommand == nil,
                      !self.isDoorCommandReady,
                      self.fastCommandNonce == nil else {
                    return
                }

                self.controlNonceRecoveryTask = nil
                self.requestFreshSecureControlNonce()
            }
        }
    }

    func stopSecureLinkWatchdog() {
        secureLinkWatchdogTask?.cancel()
        secureLinkWatchdogTask = nil
        controlNonceRecoveryTask?.cancel()
        controlNonceRecoveryTask = nil
        resetControlNonceRequest()
    }

    func resetLinkAuthentication() {
        linkAuthenticationTimeoutTask?.cancel()
        linkAuthenticationTimeoutTask = nil
        hasAuthenticatedCurrentLink = false
        linkAuthenticationInFlight = false
        linkAuthenticationAttemptCount = 0
        resetControllerNonceHandoff()
    }

    func beginControllerNonceHandoff() {
        let now = ProcessInfo.processInfo.systemUptime
        guard let generation = controllerNonceHandoffGate.begin(at: now, minimumInterval: 0) else {
            return
        }

        controllerNonceHandoffTimeoutTask?.cancel()
        controllerNonceHandoffTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.25))
            await MainActor.run {
                guard let self,
                      self.controllerNonceHandoffGate.expire(generation: generation) else { return }
                self.controllerNonceHandoffTimeoutTask = nil
#if DEBUG
                self.recordStartupTelemetry("controller_nonce_handoff_timeout", once: false)
#endif
                if self.needsFreshSecureNonce {
                    self.requestFreshSecureControlNonce()
                }
            }
        }
    }

    func completeControllerNonceHandoff() {
        controllerNonceHandoffGate.complete()
        controllerNonceHandoffTimeoutTask?.cancel()
        controllerNonceHandoffTimeoutTask = nil
    }

    func resetControllerNonceHandoff() {
        controllerNonceHandoffGate.invalidate()
        controllerNonceHandoffTimeoutTask?.cancel()
        controllerNonceHandoffTimeoutTask = nil
    }

    func completeLinkAuthentication() {
        linkAuthenticationTimeoutTask?.cancel()
        linkAuthenticationTimeoutTask = nil
        linkAuthenticationInFlight = false
        linkAuthenticationAttemptCount = 0
        hasAuthenticatedCurrentLink = true
        refreshDoorCommandDispatchReadiness()
    }

    func scheduleLinkAuthenticationTimeout() {
        linkAuthenticationTimeoutTask?.cancel()
        let generation = controllerSessionGeneration
        linkAuthenticationTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            await MainActor.run {
                guard let self,
                      self.controllerSessionGeneration == generation,
                      self.linkAuthenticationInFlight else { return }

                self.linkAuthenticationTimeoutTask = nil
                self.linkAuthenticationInFlight = false
                self.hasAuthenticatedCurrentLink = false
                self.invalidatePreparedFastDoorCommandPayloads(clearNonce: true)
                if self.linkAuthenticationAttemptCount < 2 {
                    self.requestFreshSecureControlNonce()
                } else if let peripheral = self.peripheral {
                    self.connectionState = "Reconnecting"
                    self.central?.cancelPeripheralConnection(peripheral)
                }
            }
        }
    }

    func reconnectCheckDelay(_ defaultDelay: TimeInterval) -> TimeInterval {
        min(defaultDelay, Self.activeConnectionRecoveryDelay)
    }

    func scheduleReconnectCheck(after delay: TimeInterval) {
        reconnectTimer?.invalidate()
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.recoverConnectionIfNeeded()
            }
        }
    }

    func recoverConnectionIfNeeded() {
        guard !isFirmwareDfuTransportActive,
              !isSecureCommandWriteReady,
              central?.state == .poweredOn else { return }

        if let peripheral, peripheral.state == .connecting {
            connectionState = "Connecting"
            updateProximityUnlockStatus()
            scheduleReconnectCheck(after: reconnectCheckDelay(8))
            return
        }

        if let peripheral, peripheral.state == .connected {
            connectionState = hasDiscoveredControllerCharacteristics ? "Ready" : "Discovering"
            updateProximityUnlockStatus()
            discoverControllerServices(on: peripheral)
            scheduleReconnectCheck(after: reconnectCheckDelay(8))
            return
        }

        if let peripheral, peripheral.state == .disconnecting {
            connectionState = "Reconnecting"
            updateProximityUnlockStatus()
            scheduleReconnectCheck(after: reconnectCheckDelay(8))
            return
        }

        clearDiscoveredControllerCharacteristics()
        hasRequestedControllerLockName = false
        pairingState = "Unknown"
        pairingApprovalCode = nil
        updateProximityUnlockStatus()
        if connectToKnownPeripheralIfPossible() {
            return
        }
        startScan()
    }
}
