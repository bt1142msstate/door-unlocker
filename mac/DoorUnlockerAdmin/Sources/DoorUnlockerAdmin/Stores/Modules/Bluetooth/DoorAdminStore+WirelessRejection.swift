import CoreBluetooth
import DoorUnlockerCore
import DoorUnlockerDFU
import DoorUnlockerShared
import Foundation
import os

extension DoorAdminStore {
    func handleFastCommandReject(reason: String) {
        recordRuntimeTelemetry("secure_command_rejected", details: reason, once: false)
        let rejection = DoorSecureCommandRejection(rawReason: reason)
        invalidatePreparedFastDoorCommandPayloads(clearNonce: true)
        if wirelessLinkAuthenticationInFlight {
            wirelessLinkAuthenticationInFlight = false
            hasAuthenticatedCurrentWirelessLink = false
        }
        let rejectedFirmwareUpdate = isFirmwareUpdateRunning

        if rejection.invalidatesTrust {
            hasRejectedCurrentSecurePairing = true
            setTrustedMacController(false)
        }

        if rejectedFirmwareUpdate {
            pendingFirmwareUpdatePackageURL = nil
            firmwareUpdateEntryCommandSent = false
            expectedFirmwareVerificationVersion = nil
            isAwaitingPostDfuFirmwareVerification = false
            didPostFirmwareVerificationNotification = false
            firmwareUpdateWatchdogTask?.cancel()
            firmwareUpdateWatchdogTask = nil
            firmwareDfuStartFallbackTask?.cancel()
            firmwareDfuStartFallbackTask = nil
            firmwareDfuManager.cancel()
            firmwareUpdateProgress = nil
            isFirmwareUpdateRunning = false
            switch rejection.kind {
            case .untrusted:
                firmwareUpdateStatus = "Pair this Mac over USB-C before updating firmware"
                lastError = "Pair this Mac over USB-C before updating firmware."
            case .staleNonce:
                firmwareUpdateStatus = "Controller asked for a fresh secure command"
                lastError = "Controller asked for a fresh secure command."
            case .busy:
                firmwareUpdateStatus = "Controller is busy"
                lastError = "Controller is busy."
            case .other:
                firmwareUpdateStatus = "Firmware update rejected"
                lastError = "Controller rejected firmware update."
            }
            fastDoorCommandInFlight = nil
            readStateIfPossible()
            return
        }

        if handleControllerSettingRejectIfNeeded(rejection) {
            if rejection.requiresFreshNonce {
                message = "Refreshing secure control"
            }
            fastDoorCommandInFlight = nil
            return
        }

        switch rejection.kind {
        case .busy:
            lastError = "Controller is busy."
        case .staleNonce:
            if let command = fastDoorCommandInFlight {
                pendingWirelessCommandText = command.commandText
                pendingWirelessPredictedCommand = command
                pendingWirelessCommandIntent = .doorCommand
            }
            message = "Refreshing secure control"
            lastError = nil
            requestWirelessControlNonce()
        case .untrusted:
            wirelessPairingState = "USB-C trust needed"
            lastError = "Pair this Mac over USB-C before using wireless commands."
        case .other:
            lastError = "Controller rejected the command."
        }

        fastDoorCommandInFlight = nil
        readStateIfPossible()
    }

    func updateWirelessPairingState(from state: String) {
        switch state {
        case "pairing_enabled":
            hasRejectedCurrentSecurePairing = false
            wirelessPairingState = "Pairing enabled"
        case "pairing_pending":
            hasRejectedCurrentSecurePairing = false
            wirelessPairingState = "Pairing pending"
        case "pairing_locked", "unpaired":
            if state == "unpaired" {
                hasRejectedCurrentSecurePairing = true
            }
            wirelessPairingState = "Pairing locked"
            setTrustedMacController(false)
        case "paired":
            guard !hasRejectedCurrentSecurePairing else {
                wirelessPairingState = "USB-C trust needed"
                break
            }
            wirelessPairingState = hasTrustedMacController ? "Ready" : "USB-C trust needed"
        case "locked", "unlocked", "locking", "unlocking", "timeout_set", "last_unlock":
            guard !hasRejectedCurrentSecurePairing else {
                wirelessPairingState = "USB-C trust needed"
                break
            }
            wirelessPairingState = hasTrustedMacController ? "Ready" : "USB-C trust needed"
        case "rejected":
            wirelessPairingState = hasTrustedMacController ? "Ready" : "USB-C trust needed"
            lastError = "Controller rejected the command. Pair this Mac over USB-C if it keeps happening."
        default:
            break
        }
    }

}
