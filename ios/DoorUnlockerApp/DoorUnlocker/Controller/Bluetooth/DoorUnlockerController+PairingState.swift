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
    func confirmCurrentDeviceTrustIfListed(in devices: [ConnectedControllerDevice]) {
        let localName = deviceDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !localName.isEmpty,
              devices.contains(where: {
                  $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
                      .localizedCaseInsensitiveCompare(localName) == .orderedSame
              }) else {
            return
        }

        updatePairingState(from: "paired", authoritative: true)
    }

    func isReadNotPermitted(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == CBATTError.errorDomain && nsError.code == CBATTError.Code.readNotPermitted.rawValue
    }

    func setKnownPairedController(_ isKnown: Bool) {
        hasKnownPairedController = isKnown
        UserDefaults.standard.set(isKnown, forKey: Self.knownPairedControllerKey)
    }

    func scheduleKnownPairingFallbackIfNeeded() {
        knownPairingFallbackTask?.cancel()
        knownPairingFallbackTask = nil

        guard pairingState == "Unknown",
              hasKnownPairedController,
              !hasRejectedCurrentSecurePairing,
              commandCharacteristic != nil,
              pairingCharacteristic != nil,
              peripheral?.state == .connected else {
            return
        }

        knownPairingFallbackTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            await MainActor.run {
                guard let self else { return }
                if self.promoteKnownControllerPairingIfNeeded() {
                    self.readStateIfPermitted()
                }
            }
        }
    }

    @discardableResult
    func promoteKnownControllerPairingIfNeeded() -> Bool {
        guard pairingState == "Unknown",
              hasKnownPairedController,
              !hasRejectedCurrentSecurePairing,
              commandCharacteristic != nil,
              pairingCharacteristic != nil,
              peripheral?.state == .connected else {
            return false
        }

        // Local trust is provisional until the controller accepts a signed command.
        // It must still win over stale UI recovery state; an explicit `unpaired`
        // rejection remains authoritative and clears it.
        updatePairingState(from: "paired", authoritative: true)
        sendPendingSystemCommandIfReady()
        syncLockNameIfReady()
        syncDeviceDisplayNameIfReady()
        return true
    }

    func updatePairingState(from state: String, authoritative: Bool = false) {
        let isRecoveringPairing = pairingState == "Pairing enabled"
            || pairingState == "Pairing pending"
            || pairingState == "Pairing"
            || pairingState == "Pairing locked"
            || requiresPairingRecovery

        switch state {
        case "pairing_enabled":
            knownPairingFallbackTask?.cancel()
            knownPairingFallbackTask = nil
            hasRejectedCurrentSecurePairing = false
            pairingState = "Pairing enabled"
            pairingApprovalCode = nil
            pairingAdminApprovalCode = ""
            if requiresPairingRecovery && !didSubmitPairingRecoveryRequest {
                didSubmitPairingRecoveryRequest = true
                pairThisPhone()
            }
        case "pairing_pending":
            knownPairingFallbackTask?.cancel()
            knownPairingFallbackTask = nil
            hasRejectedCurrentSecurePairing = false
            let normalizedLocalName = deviceDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
            let controllerNamesCurrentDevice = connectedDevices.contains {
                $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    .localizedCaseInsensitiveCompare(normalizedLocalName) == .orderedSame
            }
            let isCurrentDevicePairing = pairingState == "Pairing"
                || pairingApprovalCode != nil
                || (!hasTrustedPairingForSecureCommand && controllerNamesCurrentDevice)
            pairingState = "Pairing pending"
            if isCurrentDevicePairing && pairingApprovalCode == nil {
                pairingApprovalCode = try? DoorCommandAuthenticator.pairingApprovalCode()
#if DEBUG
                recordStartupTelemetry(
                    "pairing_approval_code_ready",
                    details: pairingApprovalCode ?? "unavailable",
                    once: false
                )
#endif
            } else if !isCurrentDevicePairing {
                pairingApprovalCode = nil
            }
            if pairingApprovalCode == nil && !didSubmitPairingRecoveryRequest {
                didSubmitPairingRecoveryRequest = true
                pairThisPhone()
            }
        case "pairing_locked", "unpaired":
            let controllerForgotPreviouslyTrustedIdentity = state == "unpaired"
                && (hasKnownPairedController || pairingState == "Paired")
            knownPairingFallbackTask?.cancel()
            knownPairingFallbackTask = nil
            pairingState = "Pairing locked"
            pairingApprovalCode = nil
            pairingAdminApprovalCode = ""
            setKnownPairedController(false)
            invalidatePreparedFastDoorCommandPayloads(clearNonce: true)
            if controllerForgotPreviouslyTrustedIdentity {
                requiresPairingRecovery = true
                didSubmitPairingRecoveryRequest = false
                lastError = nil
                Task { [weak self] in
                    do {
                        try await Task.sleep(for: .milliseconds(120))
                    } catch {
                        return
                    }
                    await MainActor.run {
                        guard let self, self.requiresPairingRecovery,
                              !self.didSubmitPairingRecoveryRequest else { return }
                        self.didSubmitPairingRecoveryRequest = true
                        self.pairThisPhone()
                    }
                }
            }
        case "paired":
            guard authoritative || !isRecoveringPairing else { break }
            knownPairingFallbackTask?.cancel()
            knownPairingFallbackTask = nil
            hasRejectedCurrentSecurePairing = false
            pairingState = "Paired"
            setKnownPairedController(true)
            pairingApprovalCode = nil
            pairingAdminApprovalCode = ""
            requiresPairingRecovery = false
            didSubmitPairingRecoveryRequest = false
        case "locked", "unlocked", "locking", "unlocking", "timeout_set":
            guard !isRecoveringPairing else { break }
            guard !hasRejectedCurrentSecurePairing else {
                break
            }
            knownPairingFallbackTask?.cancel()
            knownPairingFallbackTask = nil
            pairingState = "Paired"
            setKnownPairedController(true)
        default:
            break
        }

        if !isSecureCommandWriteReady || !hasTrustedPairingForSecureCommand {
            invalidatePreparedFastDoorCommandPayloads(clearNonce: true)
        }

        if isReady, !isDoorCommandReady {
            startSecureLinkWatchdogIfNeeded()
        }

        pairFromInviteIfReady()
    }
}
