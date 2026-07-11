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
    @discardableResult
    func writeAuthenticatedCommand(_ commandText: String, intent: CommandWriteIntent) -> Bool {
        let doorCommand: Command?
        if case .doorCommand(let command, _, _) = intent {
            doorCommand = command
        } else {
            doorCommand = nil
        }

        guard let peripheral, let commandCharacteristic else {
            lastError = doorCommand != nil && canQueueDoorCommandForKnownController ? nil : "Not connected"
            return false
        }

        guard hasTrustedPairingForSecureCommand else {
            lastError = "Pair this iPhone before sending commands"
            return false
        }

        if let doorCommand {
            let fastPayload: DoorCommandAuthenticator.SignedFastCommandPayload
            if hasPreparedFastDoorCommandPayloads,
               let preparedPayload = preparedFastDoorCommandPayloads[doorCommand] {
                fastPayload = preparedPayload
            } else if hasFastCommandNonce, let nonce = fastCommandNonce {
                do {
                    fastPayload = try DoorCommandAuthenticator.fastCommandPayload(for: doorCommand, nonce: nonce)
                } catch {
                    lastError = error.localizedDescription
                    return false
                }
            } else {
                lastError = nil
                return false
            }

            let action = DoorFastWritePolicy.action(
                supportsWriteWithoutResponse: commandCharacteristic.properties.contains(.writeWithoutResponse),
                payloadFits: fastPayload.data.count <= peripheral.maximumWriteValueLength(for: .withoutResponse),
                canSendWriteWithoutResponse: peripheral.canSendWriteWithoutResponse
            )
            switch action {
            case .sendNow:
                stopDoorCommandTransportRecovery()
                markFastCommandNonceConsumed()
                invalidatePreparedFastDoorCommandPayloads(clearNonce: true)
                beginControllerNonceHandoff()
                lastError = nil
                peripheral.writeValue(fastPayload.data, for: commandCharacteristic, type: .withoutResponse)
                return true
            case .waitForCapacity:
                lastError = nil
                return false
            case .unsupported:
                lastError = "Secure command is too large for this BLE connection"
                return false
            }
        }

        guard hasFastCommandNonce,
              let nonce = fastCommandNonce else {
            lastError = nil
            requestFreshSecureControlNonce()
            return false
        }

        let data: Data
        do {
            data = try DoorCommandAuthenticator.secureCommandPayload(for: commandText, nonce: nonce).data
        } catch {
            lastError = error.localizedDescription
            return false
        }

        guard let writeType = preferredWriteType(for: data, intent: intent, peripheral: peripheral, characteristic: commandCharacteristic) else {
            lastError = "Secure command is too large for this BLE connection"
            return false
        }

        lastError = nil
        markFastCommandNonceConsumed()
        invalidatePreparedFastDoorCommandPayloads(clearNonce: true)
        beginControllerNonceHandoff()
        if case .linkAuthentication = intent {
            linkAuthenticationInFlight = true
            linkAuthenticationAttemptCount += 1
            scheduleLinkAuthenticationTimeout()
        }
        if writeType == .withResponse {
            pendingCommandWriteIntents.append(intent)
        }
        peripheral.writeValue(data, for: commandCharacteristic, type: writeType)
        if writeType == .withoutResponse {
            if case .firmwareUpdate = intent {
                firmwareUpdateStatus = "Waiting for controller update mode"
                scheduleFirmwareDfuStartFallback()
            }
        }
        return true
    }
}
