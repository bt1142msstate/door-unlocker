import CoreBluetooth
import DoorUnlockerShared
import Foundation

extension DoorAdminStore {
    func telemetryCommandLabel(
        commandText: String,
        predictedDoorCommand: Command?,
        intent: WirelessCommandWriteIntent
    ) -> String {
        switch intent {
        case .doorCommand:
            return predictedDoorCommand?.rawValue ?? "door command"
        case .autoLockTimeout(let seconds):
            return "auto-lock \(seconds)s"
        case .lockName:
            return "lock name"
        case .servoAngles(let angles):
            return "angles \(angles.lockAngle)/\(angles.unlockAngle)"
        case .firmwareUpdate:
            return "firmware update"
        case .linkAuthentication:
            return "link authentication"
        case .pairingAdmin:
            return "pairing admin"
        case .generic:
            return commandText
        }
    }

    func fastDoorCommandWriteAction(
        for payload: Data,
        peripheral: CBPeripheral,
        characteristic: CBCharacteristic
    ) -> DoorFastWriteAction {
        DoorFastWritePolicy.action(
            supportsWriteWithoutResponse: characteristic.properties.contains(.writeWithoutResponse),
            payloadFits: payload.count <= peripheral.maximumWriteValueLength(for: .withoutResponse),
            canSendWriteWithoutResponse: peripheral.canSendWriteWithoutResponse
        )
    }

    func preferredWirelessWriteType(
        for payload: Data,
        intent: WirelessCommandWriteIntent,
        peripheral: CBPeripheral,
        characteristic: CBCharacteristic
    ) -> CBCharacteristicWriteType? {
        let canWriteWithoutResponse = characteristic.properties.contains(.writeWithoutResponse)
        let canWriteWithResponse = characteristic.properties.contains(.write)
        let isDoorCommand: Bool
        if case .doorCommand = intent {
            isDoorCommand = true
        } else {
            isDoorCommand = false
        }

        if isDoorCommand,
           canWriteWithResponse,
           payload.count <= peripheral.maximumWriteValueLength(for: .withResponse) {
            return .withResponse
        }

        if canWriteWithResponse,
           payload.count <= peripheral.maximumWriteValueLength(for: .withResponse) {
            return .withResponse
        }

        if canWriteWithoutResponse,
           payload.count <= peripheral.maximumWriteValueLength(for: .withoutResponse) {
            return .withoutResponse
        }

        return nil
    }
}
