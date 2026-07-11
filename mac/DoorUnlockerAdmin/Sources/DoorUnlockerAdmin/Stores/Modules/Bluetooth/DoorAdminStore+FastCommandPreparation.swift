import CoreBluetooth
import DoorUnlockerCore
import DoorUnlockerDFU
import DoorUnlockerShared
import Foundation
import os

extension DoorAdminStore {
    var needsFreshSecureNonce: Bool {
        isWirelessGattReady && !hasRejectedCurrentSecurePairing &&
            !wirelessControllerNonceHandoffGate.isInFlight &&
            inFlightControllerSetting == nil &&
            remoteSettingApplyKind == nil &&
            !hasFastCommandNonce &&
            (((hasTrustedWirelessPairingForSecureCommand && pendingFirmwareUpdatePackageURL != nil && !firmwareUpdateEntryCommandSent) ||
                (hasTrustedWirelessPairingForSecureCommand && pendingWirelessCommandText != nil)) ||
                needsWirelessLinkAuthentication ||
                (hasTrustedWirelessPairingForSecureCommand && needsFastDoorCommandPreparation))
    }

    var needsWirelessLinkAuthentication: Bool {
        !hasAuthenticatedCurrentWirelessLink &&
            !wirelessLinkAuthenticationInFlight &&
            fastDoorCommandInFlight == nil &&
            pendingWirelessCommandText == nil &&
            pendingFirmwareUpdatePackageURL == nil &&
            !isApplyingControllerSetting
    }

    var needsFastDoorCommandPreparation: Bool {
        hasAuthenticatedCurrentWirelessLink &&
            fastDoorCommandInFlight == nil &&
            pendingWirelessCommandText == nil &&
            pendingFirmwareUpdatePackageURL == nil &&
            !isApplyingControllerSetting &&
            !hasPreparedFastDoorCommandPayloads
    }

    func stopSecureLinkWatchdog() {
        secureLinkWatchdogTask?.cancel()
        secureLinkWatchdogTask = nil
        queuedWirelessCommandNonceRequestCount = 0
        resetWirelessControlNonceRequest()
    }

    func resetWirelessLinkAuthentication() {
        wirelessLinkAuthenticationTimeoutTask?.cancel()
        wirelessLinkAuthenticationTimeoutTask = nil
        hasAuthenticatedCurrentWirelessLink = false
        wirelessLinkAuthenticationInFlight = false
        wirelessLinkAuthenticationAttemptCount = 0
        resetWirelessControllerNonceHandoff()
    }

    func markWirelessConnectionObserved() {
        lastControllerActivityAt = .now
    }

    func completeWirelessLinkAuthentication() {
        wirelessLinkAuthenticationTimeoutTask?.cancel()
        wirelessLinkAuthenticationTimeoutTask = nil
        wirelessLinkAuthenticationInFlight = false
        wirelessLinkAuthenticationAttemptCount = 0
        hasAuthenticatedCurrentWirelessLink = true
        setTrustedMacController(true)
        wirelessPairingState = "Ready"
        recordRuntimeTelemetry("door_command_usable", details: "link_authenticated")
    }

    func scheduleWirelessLinkAuthenticationTimeout() {
        wirelessLinkAuthenticationTimeoutTask?.cancel()
        wirelessLinkAuthenticationTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            await MainActor.run {
                guard let self, self.wirelessLinkAuthenticationInFlight else { return }
                self.wirelessLinkAuthenticationTimeoutTask = nil
                self.wirelessLinkAuthenticationInFlight = false
                self.hasAuthenticatedCurrentWirelessLink = false
                self.invalidatePreparedFastDoorCommandPayloads(clearNonce: true)
                if self.wirelessLinkAuthenticationAttemptCount < 2 {
                    self.requestWirelessControlNonceWithoutWatchdog()
                } else {
                    self.stopWirelessSession(reason: "Reconnecting")
                    self.scanBluetooth()
                }
            }
        }
    }

    func prepareFastDoorCommandPayloads(for nonce: Data) {
        preparedFastDoorCommandGeneration += 1
        let generation = preparedFastDoorCommandGeneration
        let commandOrder = DoorCommand.preparationOrder(
            preferred: pendingWirelessPredictedCommand,
            isUnlocked: status.isUnlocked
        )

        preparedFastDoorCommandTask?.cancel()
        preparedFastDoorCommandTask = Task { [weak self] in
            for command in commandOrder {
                let payload = try? await Task.detached(priority: .userInitiated) {
                    try DoorCommandAuthenticator.fastCommandPayload(
                        for: command,
                        nonce: nonce
                    )
                }.value

                guard !Task.isCancelled else { return }
                guard let payload else {
                    await MainActor.run {
                        guard let self,
                              self.preparedFastDoorCommandGeneration == generation,
                              self.fastCommandNonce == nonce else {
                            return
                        }

                        self.preparedFastDoorCommandTask = nil
                        self.fastCommandNonce = nil
                        self.startSecureLinkWatchdogIfNeeded()
                    }
                    return
                }

                let shouldContinue = await MainActor.run {
                    guard let self,
                          self.preparedFastDoorCommandGeneration == generation,
                          self.fastCommandNonce == nonce,
                          self.hasTrustedWirelessPairingForSecureCommand else {
                        return false
                    }

                    self.preparedFastDoorCommandPayloads[command] = payload
                    if self.preparedFastDoorCommandPayloads.count == 1 {
                        self.recordRuntimeTelemetry("first_fast_payload_ready", details: command.rawValue)
                        self.recordRuntimeTelemetry("door_command_usable", details: "fast_payload_ready")
                    }
                    self.stopSecureLinkWatchdog()
                    self.sendQueuedWirelessCommand()
                    return self.preparedFastDoorCommandGeneration == generation &&
                        self.fastCommandNonce == nonce
                }

                guard shouldContinue else { return }
            }

            await MainActor.run {
                guard let self,
                      self.preparedFastDoorCommandGeneration == generation,
                      self.fastCommandNonce == nonce,
                      self.hasTrustedWirelessPairingForSecureCommand else {
                    return
                }

                self.preparedFastDoorCommandTask = nil
                self.stopSecureLinkWatchdog()
                self.sendQueuedWirelessCommand()
            }
        }
    }

    func invalidatePreparedFastDoorCommandPayloads(clearNonce: Bool = false) {
        preparedFastDoorCommandGeneration += 1
        preparedFastDoorCommandTask?.cancel()
        preparedFastDoorCommandTask = nil
        preparedFastDoorCommandPayloads.removeAll()
        if clearNonce {
            fastCommandNonce = nil
        }
    }

    func applyFastCommandNonce(_ nonce: Data) {
        guard DoorSecureNonceAcceptancePolicy.shouldAccept(
            receivedNonce: nonce,
            lastConsumedNonce: lastConsumedFastCommandNonce
        ) else {
            recordRuntimeTelemetry("consumed_nonce_duplicate_ignored", once: false)
            return
        }
        completeWirelessControllerNonceHandoff()
        firmwareLog.info("Secure nonce received pendingFirmware=\(self.pendingFirmwareUpdatePackageURL != nil, privacy: .public)")
        stopSecureLinkWatchdog()
        fastCommandNonce = nonce
        queuedWirelessCommandNonceRequestCount = 0
        recordRuntimeTelemetry("secure_nonce_received")
        recordRuntimeTelemetry("door_command_usable", details: "nonce_ready")
        if sendPendingFirmwareUpdateCommandIfReady() {
            return
        }
        if sendQueuedWirelessNonDoorCommandIfReady() {
            return
        }
        if sendWirelessLinkAuthenticationProbeIfNeeded() {
            return
        }
        prepareFastDoorCommandPayloads(for: nonce)
    }

    func markFastCommandNonceConsumed() {
        if let fastCommandNonce {
            lastConsumedFastCommandNonce = fastCommandNonce
        }
    }

    @discardableResult
    func sendWirelessLinkAuthenticationProbeIfNeeded() -> Bool {
        guard needsWirelessLinkAuthentication,
              fastCommandNonce != nil,
              isWirelessGattReady,
              !hasRejectedCurrentSecurePairing else {
            return false
        }

        if sendWirelessCommandText("GET_LOCK_NAME", intent: .linkAuthentication).isAccepted {
            recordRuntimeTelemetry("wireless_auth_probe_sent", once: false)
            return true
        }
        return false
    }

    @discardableResult
    func sendQueuedWirelessNonDoorCommandIfReady() -> Bool {
        guard pendingWirelessCommandText != nil,
              !hasQueuedWirelessDoorCommand else {
            return false
        }

        sendQueuedWirelessCommand()
        return true
    }

    var hasQueuedWirelessDoorCommand: Bool {
        guard let pendingWirelessCommandIntent else { return false }
        if case .doorCommand = pendingWirelessCommandIntent {
            return true
        }

        return false
    }
}
