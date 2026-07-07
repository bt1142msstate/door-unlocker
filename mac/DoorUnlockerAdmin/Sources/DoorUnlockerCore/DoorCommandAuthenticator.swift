import CryptoKit
import Foundation

public enum DoorCommandAuthenticator {
    public enum FastCommand {
        case unlock
        case lock
    }

    public struct SignedFastCommandPayload {
        public let data: Data
    }

    public enum AuthError: LocalizedError {
        case signingKeyReadFailed
        case signingKeySaveFailed
        case unsupportedCommand(String)

        public var errorDescription: String? {
            switch self {
            case .signingKeyReadFailed:
                return "Could not read the local signing key."
            case .signingKeySaveFailed:
                return "Could not save the local signing key."
            case .unsupportedCommand(let command):
                return "Unsupported secure command: \(command)"
            }
        }
    }

    private enum SigningIdentity {
        case software(P256.Signing.PrivateKey)

        var publicKeyX963Representation: Data {
            switch self {
            case .software(let key):
                return key.publicKey.x963Representation
            }
        }

        func signature(for data: Data) throws -> Data {
            switch self {
            case .software(let key):
                return try key.signature(for: data).rawRepresentation
            }
        }
    }

    private final class AuthCache: @unchecked Sendable {
        let lock = NSLock()
        var identity: SigningIdentity?
        var keyFingerprint: Data?
    }

    private static let signingKeyDirectoryName = "DoorUnlockerAdmin"
    private static let signingKeyFileName = "signing-key-v1.raw"
    private static let pairingPayloadWithNameVersion: UInt8 = 0x01
    private static let maximumPairingDeviceNameLength = 24
    private static let fastCommandVersion: UInt8 = 0x03
    private static let fastCommandUnlockOp: UInt8 = 0x01
    private static let fastCommandLockOp: UInt8 = 0x02
    private static let fastCommandGetLockNameOp: UInt8 = 0x10
    private static let fastCommandGetServoAnglesOp: UInt8 = 0x11
    private static let fastCommandGetLastUnlockOp: UInt8 = 0x12
    private static let fastCommandSetLockNameOp: UInt8 = 0x20
    private static let fastCommandSetServoAnglesOp: UInt8 = 0x21
    private static let fastCommandSetTimeoutOp: UInt8 = 0x22
    private static let fastCommandSetDeviceNameOp: UInt8 = 0x23
    private static let fastCommandEnterOtaDfuOp: UInt8 = 0x30
    private static let fastCommandNonceLength = 16
    private static let fastCommandKeyFingerprintLength = 8
    private static let fastCommandMaxPayloadLength = 129
    private static let fastCommandSignatureDomain = Data("DoorUnlocker:v3:command".utf8)
    private static let cache = AuthCache()

    public static func prewarm() {
        guard let identity = try? identity() else { return }
        _ = try? fastCommandKeyFingerprint(for: identity)
        _ = try? identity.signature(for: fastCommandSignatureDomain)
    }

    public static func pairingPayload(deviceName: String) throws -> Data {
        var payload = Data([pairingPayloadWithNameVersion])
        payload.append(try identity().publicKeyX963Representation)
        payload.append(sanitizedDeviceNameData(deviceName))
        return payload
    }

    public static func pairingPayloadHex(deviceName: String) throws -> String {
        try pairingPayload(deviceName: deviceName)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    public static func publicKeyX963Representation() throws -> Data {
        try identity().publicKeyX963Representation
    }

    public static func fastCommandPayload(for command: FastCommand, nonce: Data) throws -> SignedFastCommandPayload {
        let op: UInt8 = command == .unlock ? fastCommandUnlockOp : fastCommandLockOp
        return try v3CommandPayload(op: op, payload: Data(), nonce: nonce)
    }

    public static func secureCommandPayload(for commandText: String, nonce: Data) throws -> SignedFastCommandPayload {
        let encodedCommand = try v3CommandEncoding(for: commandText)
        return try v3CommandPayload(op: encodedCommand.op, payload: encodedCommand.payload, nonce: nonce)
    }

    private static func v3CommandPayload(op: UInt8, payload: Data, nonce: Data) throws -> SignedFastCommandPayload {
        guard nonce.count == fastCommandNonceLength,
              payload.count <= fastCommandMaxPayloadLength else {
            throw AuthError.signingKeyReadFailed
        }

        let identity = try identity()
        let fingerprint = try fastCommandKeyFingerprint(for: identity)
        var unsignedPacket = Data([fastCommandVersion, op])
        unsignedPacket.append(fingerprint)
        unsignedPacket.append(nonce)
        unsignedPacket.append(UInt8(payload.count))
        unsignedPacket.append(payload)

        var signedMessage = fastCommandSignatureDomain
        signedMessage.append(unsignedPacket)
        let signature = try identity.signature(for: signedMessage)

        var packet = unsignedPacket
        packet.append(signature)
        return SignedFastCommandPayload(data: packet)
    }

    private static func v3CommandEncoding(for commandText: String) throws -> (op: UInt8, payload: Data) {
        if commandText == "GET_LOCK_NAME" {
            return (fastCommandGetLockNameOp, Data())
        }
        if commandText == "GET_ANGLES" {
            return (fastCommandGetServoAnglesOp, Data())
        }
        if commandText == "GET_LAST_UNLOCK" {
            return (fastCommandGetLastUnlockOp, Data())
        }
        if commandText == "ENTER_OTA_DFU" {
            return (fastCommandEnterOtaDfuOp, Data())
        }
        if let name = payloadValue(in: commandText, prefix: "SET_LOCK_NAME:") {
            return (fastCommandSetLockNameOp, sanitizedDeviceNameData(name))
        }
        if let name = payloadValue(in: commandText, prefix: "SET_NAME:") {
            return (fastCommandSetDeviceNameOp, sanitizedDeviceNameData(name))
        }
        if let value = payloadValue(in: commandText, prefix: "SET_TIMEOUT:"),
           let seconds = UInt16(value) {
            return (fastCommandSetTimeoutOp, Data([UInt8(seconds >> 8), UInt8(seconds & 0xff)]))
        }
        if let value = payloadValue(in: commandText, prefix: "SET_ANGLES:") {
            let parts = value.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2,
               let lockAngle = UInt8(parts[0]),
               let unlockAngle = UInt8(parts[1]) {
                return (fastCommandSetServoAnglesOp, Data([lockAngle, unlockAngle]))
            }
        }

        throw AuthError.unsupportedCommand(commandText)
    }

    private static func payloadValue(in commandText: String, prefix: String) -> String? {
        guard commandText.hasPrefix(prefix) else { return nil }
        return String(commandText.dropFirst(prefix.count))
    }

    private static func fastCommandKeyFingerprint() throws -> Data {
        try fastCommandKeyFingerprint(for: identity())
    }

    private static func fastCommandKeyFingerprint(for identity: SigningIdentity) throws -> Data {
        cache.lock.lock()
        if let keyFingerprint = cache.keyFingerprint {
            cache.lock.unlock()
            return keyFingerprint
        }
        cache.lock.unlock()

        let digest = SHA256.hash(data: identity.publicKeyX963Representation)
        let fingerprint = Data(digest.prefix(fastCommandKeyFingerprintLength))

        cache.lock.lock()
        cache.keyFingerprint = fingerprint
        cache.lock.unlock()

        return fingerprint
    }

    private static func sanitizedDeviceNameData(_ name: String) -> Data {
        Data(DoorDeviceNameNormalizer.normalized(name, fallback: "Mac", maximumLength: maximumPairingDeviceNameLength).utf8)
    }

    private static func identity() throws -> SigningIdentity {
        cache.lock.lock()
        if let identity = cache.identity {
            cache.lock.unlock()
            return identity
        }
        cache.lock.unlock()

        if let data = try readSigningKeyData() {
            if let key = try? P256.Signing.PrivateKey(rawRepresentation: data) {
                let identity = SigningIdentity.software(key)
                cache.lock.lock()
                cache.identity = identity
                cache.lock.unlock()
                return identity
            }
            try? FileManager.default.removeItem(at: signingKeyURL())
        }

        let softwareKey = P256.Signing.PrivateKey()
        try saveSigningKeyData(softwareKey.rawRepresentation)
        let identity = SigningIdentity.software(softwareKey)
        cache.lock.lock()
        cache.identity = identity
        cache.keyFingerprint = nil
        cache.lock.unlock()
        return identity
    }

    private static func signingKeyURL() throws -> URL {
        guard let applicationSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw AuthError.signingKeyReadFailed
        }

        return applicationSupportURL
            .appendingPathComponent(signingKeyDirectoryName, isDirectory: true)
            .appendingPathComponent(signingKeyFileName, isDirectory: false)
    }

    private static func readSigningKeyData() throws -> Data? {
        let url = try signingKeyURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        do {
            return try Data(contentsOf: url)
        } catch {
            throw AuthError.signingKeyReadFailed
        }
    }

    private static func saveSigningKeyData(_ data: Data) throws {
        let url = try signingKeyURL()
        let directoryURL = url.deletingLastPathComponent()

        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try data.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        } catch {
            throw AuthError.signingKeySaveFailed
        }
    }

}
