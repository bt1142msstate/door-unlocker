import CoreBluetooth
import DoorUnlockerCore
import DoorUnlockerDFU
import DoorUnlockerShared
import Foundation
import os

extension DoorAdminStore {
    var needsFreshSecureNonce: Bool {
        isWirelessReady &&
            !hasFastCommandNonce &&
            ((pendingFirmwareUpdatePackageURL != nil && !firmwareUpdateEntryCommandSent) ||
                pendingWirelessCommandText != nil ||
                needsWirelessLinkAuthentication ||
                needsFastDoorCommandPreparation)
    }

    var needsWirelessLinkAuthentication: Bool {
        !hasAuthenticatedCurrentWirelessLink &&
            !wirelessLinkAuthenticationInFlight &&
            pendingWirelessCommandText == nil &&
            pendingFirmwareUpdatePackageURL == nil
    }

    var needsFastDoorCommandPreparation: Bool {
        hasAuthenticatedCurrentWirelessLink &&
            pendingWirelessCommandText == nil &&
            pendingFirmwareUpdatePackageURL == nil &&
            !hasPreparedFastDoorCommandPayloads
    }

    func stopSecureLinkWatchdog() {
        secureLinkWatchdogTask?.cancel()
        secureLinkWatchdogTask = nil
        queuedWirelessCommandNonceRequestCount = 0
        resetWirelessControlNonceRequest()
    }

    func resetWirelessLinkAuthentication() {
        hasAuthenticatedCurrentWirelessLink = false
        wirelessLinkAuthenticationInFlight = false
    }

    func markWirelessConnectionObserved() {
        guard !isConnected else { return }
        var nextStatus = status
        nextStatus.connectedCount = max(nextStatus.connectedCount, 1)
        nextStatus.maxConnections = max(nextStatus.maxConnections, 4)
        status = nextStatus
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

    @discardableResult
    func sendWirelessLinkAuthenticationProbeIfNeeded() -> Bool {
        guard needsWirelessLinkAuthentication,
              fastCommandNonce != nil,
              isWirelessReady else {
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
