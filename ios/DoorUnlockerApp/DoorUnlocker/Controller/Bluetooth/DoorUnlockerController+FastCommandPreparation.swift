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
    func prepareFastDoorCommandPayloads(for nonce: Data) {
        preparedFastDoorCommandGeneration += 1
        let generation = preparedFastDoorCommandGeneration
        let commandOrder = DoorCommand.preparationOrder(
            preferred: pendingFreshNonceDoorCommand?.command,
            isUnlocked: isUnlocked
        )

        preparedFastDoorCommandTask?.cancel()
        preparedFastDoorCommandTask = Task { [weak self] in
            for command in commandOrder {
                let payload = try? await Task.detached(priority: .userInitiated) {
                    try DoorCommandAuthenticator.fastCommandPayload(for: command, nonce: nonce)
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
                          self.hasTrustedPairingForSecureCommand else {
                        return false
                    }

                    self.preparedFastDoorCommandPayloads[command] = payload
#if DEBUG
                    if self.preparedFastDoorCommandPayloads.count == 1 {
                        self.recordStartupTelemetry("first_fast_payload_ready", details: command.rawValue)
                    }
#endif
                    self.stopSecureLinkWatchdog()
                    if self.sendPendingFreshNonceDoorCommandIfReady() {
                        return false
                    }
                    self.sendPendingSystemCommandIfReady()
                    _ = self.runProximityUnlockIfReady()
                    return self.preparedFastDoorCommandGeneration == generation &&
                        self.fastCommandNonce == nonce
                }

                guard shouldContinue else { return }
            }

            await MainActor.run {
                guard let self,
                      self.preparedFastDoorCommandGeneration == generation,
                      self.fastCommandNonce == nonce,
                      self.hasTrustedPairingForSecureCommand else {
                    return
                }

                self.preparedFastDoorCommandTask = nil
                self.stopSecureLinkWatchdog()
                if self.sendPendingFreshNonceDoorCommandIfReady() {
                    return
                }
                self.sendPendingSystemCommandIfReady()
                _ = self.runProximityUnlockIfReady()
                guard self.fastCommandNonce == nonce else { return }
                self.schedulePostReadySync()
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
        resetControlNonceRequest()
        guard DoorSecureNonceAcceptancePolicy.shouldAccept(
            receivedNonce: nonce,
            lastConsumedNonce: lastConsumedFastCommandNonce
        ) else {
#if DEBUG
            recordStartupTelemetry("consumed_nonce_duplicate_ignored", once: false)
#endif
            return
        }
        completeControllerNonceHandoff()
        fastCommandNonce = nonce
#if DEBUG
        recordStartupTelemetry("secure_nonce_received")
        recordStartupTelemetry("door_command_usable", details: "nonce_ready")
#endif
        if pendingFirmwareUpdatePackageURL != nil,
           sendPendingFirmwareUpdateCommandIfReady() {
            return
        }
        if pendingFreshNonceDoorCommand == nil,
           sendQueuedControllerSettingIfReady() {
            return
        }
        if sendLinkAuthenticationProbeIfNeeded() {
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
    func sendLinkAuthenticationProbeIfNeeded() -> Bool {
        guard needsLinkAuthentication,
              fastCommandNonce != nil,
              isReady else {
            return false
        }

        if writeAuthenticatedCommand("GET_LOCK_NAME", intent: .linkAuthentication) {
#if DEBUG
            recordStartupTelemetry("link_auth_probe_sent", once: false)
#endif
            return true
        }

        return false
    }

    func preferredWriteType(
        for data: Data,
        intent: CommandWriteIntent,
        peripheral: CBPeripheral,
        characteristic: CBCharacteristic
    ) -> CBCharacteristicWriteType? {
        let canWriteWithoutResponse = characteristic.properties.contains(.writeWithoutResponse)
        let canWriteWithResponse = characteristic.properties.contains(.write)
        let isDoorCommand: Bool
        if case .doorCommand(_, _, _) = intent {
            isDoorCommand = true
        } else {
            isDoorCommand = false
        }
        if isDoorCommand,
           canWriteWithResponse,
           data.count <= peripheral.maximumWriteValueLength(for: .withResponse) {
            return .withResponse
        }

        if canWriteWithResponse,
           data.count <= peripheral.maximumWriteValueLength(for: .withResponse) {
            return .withResponse
        }

        if canWriteWithoutResponse,
           data.count <= peripheral.maximumWriteValueLength(for: .withoutResponse) {
            return .withoutResponse
        }

        return nil
    }

    func authenticateAndSendUnlock() async {
        guard !isAuthenticatingUnlock else { return }

        lastError = nil
        isAuthenticatingUnlock = true
        defer { isAuthenticatingUnlock = false }

        let context = LAContext()
        context.localizedCancelTitle = "Cancel"

        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            lastError = "Set up Face ID or a device passcode to protect unlock"
            return
        }

        do {
            let allowed = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Authenticate to unlock Door Unlocker."
            )
            guard allowed else { return }
            sendAuthenticated(.unlock)
        } catch {
            if isAuthenticationCancellation(error) {
                lastError = nil
            } else {
                lastError = "Unlock authentication failed"
            }
        }
    }

    func authenticateSettingsAccess() async {
        guard !isAuthenticatingSettings else { return }

        let authenticationGeneration = settingsAuthenticationGeneration
        lastError = nil
        isAuthenticatingSettings = true
        defer { isAuthenticatingSettings = false }

        let context = LAContext()
        context.localizedCancelTitle = "Cancel"

        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            lastError = "Set up Face ID or a device passcode to change settings"
            return
        }

        do {
            let allowed = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Authenticate to open Door Unlocker settings."
            )
            guard allowed,
                  authenticationGeneration == settingsAuthenticationGeneration else { return }
            areSettingsUnlocked = true
        } catch {
            if isAuthenticationCancellation(error) {
                lastError = nil
            } else {
                lastError = "Settings authentication failed"
            }
        }
    }

    func isAuthenticationCancellation(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == LAError.errorDomain,
              let code = LAError.Code(rawValue: nsError.code) else {
            return false
        }

        switch code {
        case .userCancel, .systemCancel, .appCancel:
            return true
        default:
            return false
        }
    }
}
