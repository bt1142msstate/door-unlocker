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
        guard let peripheral,
              let controlCharacteristic else {
            startSecureLinkWatchdogIfNeeded()
            return
        }

#if DEBUG
        recordStartupTelemetry("secure_nonce_requested")
#endif
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

        requestNonceViaCommandIfPossible()
        startSecureLinkWatchdogIfNeeded()
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
        scheduleControlNonceRecoveryIfNeeded(
            after: .nanoseconds(Int64(DoorControllerSettingConfirmationPolicy.controllerIssuedNonceReadDelayNanoseconds))
        )
    }

    func scheduleControlNonceRecoveryIfNeeded(after delay: Duration = .milliseconds(80)) {
        guard isReady,
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
    }

    func resetLinkAuthentication() {
        hasAuthenticatedCurrentLink = false
        linkAuthenticationInFlight = false
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
