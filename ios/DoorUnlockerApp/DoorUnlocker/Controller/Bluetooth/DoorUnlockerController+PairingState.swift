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

        updatePairingState(from: "paired")
        sendPendingSystemCommandIfReady()
        syncLockNameIfReady()
        syncDeviceDisplayNameIfReady()
        return true
    }

    func updatePairingState(from state: String) {
        switch state {
        case "pairing_enabled":
            knownPairingFallbackTask?.cancel()
            knownPairingFallbackTask = nil
            hasRejectedCurrentSecurePairing = false
            pairingState = "Pairing enabled"
            pairingApprovalCode = nil
            pairingAdminApprovalCode = ""
        case "pairing_pending":
            knownPairingFallbackTask?.cancel()
            knownPairingFallbackTask = nil
            hasRejectedCurrentSecurePairing = false
            let isCurrentDevicePairing = pairingState == "Pairing" || pairingApprovalCode != nil
            pairingState = "Pairing pending"
            if isCurrentDevicePairing && pairingApprovalCode == nil {
                pairingApprovalCode = try? DoorCommandAuthenticator.pairingApprovalCode()
            } else if !isCurrentDevicePairing {
                pairingApprovalCode = nil
            }
        case "pairing_locked", "unpaired":
            knownPairingFallbackTask?.cancel()
            knownPairingFallbackTask = nil
            pairingState = "Pairing locked"
            pairingApprovalCode = nil
            pairingAdminApprovalCode = ""
            setKnownPairedController(false)
            invalidatePreparedFastDoorCommandPayloads(clearNonce: true)
        case "paired":
            knownPairingFallbackTask?.cancel()
            knownPairingFallbackTask = nil
            hasRejectedCurrentSecurePairing = false
            pairingState = "Paired"
            setKnownPairedController(true)
            pairingApprovalCode = nil
            pairingAdminApprovalCode = ""
        case "locked", "unlocked", "locking", "unlocking", "timeout_set":
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
