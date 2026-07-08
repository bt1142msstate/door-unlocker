import CryptoKit
import DoorUnlockerShared
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
    private static let cache = AuthCache()

    public static func prewarm() {
        guard let identity = try? identity() else { return }
        _ = try? fastCommandKeyFingerprint(for: identity)
        _ = try? identity.signature(for: DoorSecureCommandCodec.signatureDomain)
    }

    public static func pairingPayload(deviceName: String) throws -> Data {
        try DoorSecureCommandCodec.pairingPayload(
            publicKey: identity().publicKeyX963Representation,
            deviceName: deviceName,
            fallbackName: "Mac"
        )
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
        let secureCommand: DoorSecureCommandCodec.FastCommand = command == .unlock ? .unlock : .lock
        let encodedCommand = DoorSecureCommandCodec.encodedFastCommand(secureCommand)
        return try v3CommandPayload(encodedCommand, nonce: nonce)
    }

    public static func secureCommandPayload(for commandText: String, nonce: Data) throws -> SignedFastCommandPayload {
        let encodedCommand = try DoorSecureCommandCodec.encodedCommand(commandText: commandText)
        return try v3CommandPayload(encodedCommand, nonce: nonce)
    }

    private static func v3CommandPayload(_ encodedCommand: DoorSecureCommandCodec.EncodedCommand, nonce: Data) throws -> SignedFastCommandPayload {
        let identity = try identity()
        let fingerprint = try fastCommandKeyFingerprint(for: identity)
        let unsignedPacket = try DoorSecureCommandCodec.unsignedPacket(
            op: encodedCommand.op,
            payload: encodedCommand.payload,
            nonce: nonce,
            keyFingerprint: fingerprint
        )
        let signedMessage = DoorSecureCommandCodec.messageToSign(unsignedPacket: unsignedPacket)
        let signature = try identity.signature(for: signedMessage)

        return SignedFastCommandPayload(
            data: DoorSecureCommandCodec.signedPacket(unsignedPacket: unsignedPacket, signature: signature)
        )
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

        let fingerprint = DoorSecureCommandCodec.keyFingerprint(publicKey: identity.publicKeyX963Representation)

        cache.lock.lock()
        cache.keyFingerprint = fingerprint
        cache.lock.unlock()

        return fingerprint
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
