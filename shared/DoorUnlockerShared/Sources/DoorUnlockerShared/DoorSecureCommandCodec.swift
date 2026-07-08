import CryptoKit
import Foundation

public enum DoorSecureCommandCodec {
    public enum FastCommand {
        case unlock
        case lock
    }

    public struct EncodedCommand: Equatable {
        public let op: UInt8
        public let payload: Data

        public init(op: UInt8, payload: Data) {
            self.op = op
            self.payload = payload
        }
    }

    public enum CodecError: LocalizedError {
        case invalidNonceLength
        case payloadTooLong
        case unsupportedCommand(String)

        public var errorDescription: String? {
            switch self {
            case .invalidNonceLength:
                return "Secure command nonce must be \(nonceLength) bytes."
            case .payloadTooLong:
                return "Secure command payload is too long."
            case .unsupportedCommand(let command):
                return "Unsupported secure command: \(command)"
            }
        }
    }

    public static let pairingPayloadWithNameVersion: UInt8 = 0x01
    public static let maximumPairingDeviceNameLength = 24
    public static let fastCommandVersion: UInt8 = 0x03
    public static let fastCommandUnlockOp: UInt8 = 0x01
    public static let fastCommandLockOp: UInt8 = 0x02
    public static let fastCommandGetLockNameOp: UInt8 = 0x10
    public static let fastCommandGetServoAnglesOp: UInt8 = 0x11
    public static let fastCommandGetLastUnlockOp: UInt8 = 0x12
    public static let fastCommandSetLockNameOp: UInt8 = 0x20
    public static let fastCommandSetServoAnglesOp: UInt8 = 0x21
    public static let fastCommandSetTimeoutOp: UInt8 = 0x22
    public static let fastCommandSetDeviceNameOp: UInt8 = 0x23
    public static let fastCommandPairingEnableOp: UInt8 = 0x24
    public static let fastCommandPairingDisableOp: UInt8 = 0x25
    public static let fastCommandPairingApproveOp: UInt8 = 0x26
    public static let fastCommandPairingRejectOp: UInt8 = 0x27
    public static let fastCommandEnterOtaDfuOp: UInt8 = 0x30
    public static let nonceLength = 16
    public static let keyFingerprintLength = 8
    public static let maxPayloadLength = 129
    public static let signatureDomain = Data("DoorUnlocker:v3:command".utf8)

    public static func pairingPayload(publicKey: Data, deviceName: String, fallbackName: String) -> Data {
        var payload = Data([pairingPayloadWithNameVersion])
        payload.append(publicKey)
        payload.append(sanitizedDeviceNameData(deviceName, fallbackName: fallbackName))
        return payload
    }

    public static func approvalCode(publicKey: Data) -> String {
        let digest = SHA256.hash(data: publicKey)
        let prefix = digest.prefix(2).reduce(UInt16(0)) { partialResult, byte in
            (partialResult << 8) | UInt16(byte)
        }
        return String(format: "%04u", prefix % 10_000)
    }

    public static func encodedFastCommand(_ command: FastCommand) -> EncodedCommand {
        EncodedCommand(
            op: command == .unlock ? fastCommandUnlockOp : fastCommandLockOp,
            payload: Data()
        )
    }

    public static func encodedCommand(commandText: String) throws -> EncodedCommand {
        if commandText == "GET_LOCK_NAME" {
            return EncodedCommand(op: fastCommandGetLockNameOp, payload: Data())
        }
        if commandText == "GET_ANGLES" {
            return EncodedCommand(op: fastCommandGetServoAnglesOp, payload: Data())
        }
        if commandText == "GET_LAST_UNLOCK" {
            return EncodedCommand(op: fastCommandGetLastUnlockOp, payload: Data())
        }
        if commandText == "ENTER_OTA_DFU" {
            return EncodedCommand(op: fastCommandEnterOtaDfuOp, payload: Data())
        }
        if let name = payloadValue(in: commandText, prefix: "SET_LOCK_NAME:") {
            return EncodedCommand(
                op: fastCommandSetLockNameOp,
                payload: sanitizedDeviceNameData(name, fallbackName: "Lock")
            )
        }
        if let name = payloadValue(in: commandText, prefix: "SET_NAME:") {
            return EncodedCommand(
                op: fastCommandSetDeviceNameOp,
                payload: sanitizedDeviceNameData(name, fallbackName: "Device")
            )
        }
        if commandText == "PAIR_ON" {
            return EncodedCommand(op: fastCommandPairingEnableOp, payload: Data())
        }
        if commandText == "PAIR_OFF" {
            return EncodedCommand(op: fastCommandPairingDisableOp, payload: Data())
        }
        if let code = payloadValue(in: commandText, prefix: "PAIR_APPROVE:") {
            let trimmedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
            return EncodedCommand(op: fastCommandPairingApproveOp, payload: Data(trimmedCode.utf8))
        }
        if commandText == "PAIR_REJECT" {
            return EncodedCommand(op: fastCommandPairingRejectOp, payload: Data())
        }
        if let value = payloadValue(in: commandText, prefix: "SET_TIMEOUT:"),
           let seconds = UInt16(value) {
            return EncodedCommand(
                op: fastCommandSetTimeoutOp,
                payload: Data([UInt8(seconds >> 8), UInt8(seconds & 0xff)])
            )
        }
        if let value = payloadValue(in: commandText, prefix: "SET_ANGLES:") {
            let parts = value.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2,
               let lockAngle = UInt8(parts[0]),
               let unlockAngle = UInt8(parts[1]) {
                return EncodedCommand(op: fastCommandSetServoAnglesOp, payload: Data([lockAngle, unlockAngle]))
            }
        }

        throw CodecError.unsupportedCommand(commandText)
    }

    public static func keyFingerprint(publicKey: Data) -> Data {
        let digest = SHA256.hash(data: publicKey)
        return Data(digest.prefix(keyFingerprintLength))
    }

    public static func unsignedPacket(op: UInt8, payload: Data, nonce: Data, keyFingerprint: Data) throws -> Data {
        guard nonce.count == nonceLength else {
            throw CodecError.invalidNonceLength
        }
        guard payload.count <= maxPayloadLength else {
            throw CodecError.payloadTooLong
        }

        var packet = Data([fastCommandVersion, op])
        packet.append(keyFingerprint.prefix(keyFingerprintLength))
        packet.append(nonce)
        packet.append(UInt8(payload.count))
        packet.append(payload)
        return packet
    }

    public static func messageToSign(unsignedPacket: Data) -> Data {
        var signedMessage = signatureDomain
        signedMessage.append(unsignedPacket)
        return signedMessage
    }

    public static func signedPacket(unsignedPacket: Data, signature: Data) -> Data {
        var packet = unsignedPacket
        packet.append(signature)
        return packet
    }

    public static func sanitizedDeviceNameData(_ name: String, fallbackName: String) -> Data {
        Data(DoorNameNormalizer.normalized(
            name,
            fallback: fallbackName,
            maximumLength: maximumPairingDeviceNameLength
        ).utf8)
    }

    private static func payloadValue(in commandText: String, prefix: String) -> String? {
        guard commandText.hasPrefix(prefix) else { return nil }
        return String(commandText.dropFirst(prefix.count))
    }
}
