import CryptoKit
import DoorUnlockerShared
import Foundation
import Security

enum DoorCommandAuthenticator {
    struct SignedFastCommandPayload {
        let data: Data
    }

    enum AuthError: LocalizedError {
        case keychainReadFailed(OSStatus)
        case keychainSaveFailed(OSStatus)
        case secureEnclaveUnavailable
        case secureEnclaveAccessControlFailed
        case signingKeyUnavailable
        case unsupportedCommand(String)

        var errorDescription: String? {
            switch self {
            case .keychainReadFailed(let status):
                return "Could not read signing key from Keychain (\(status))."
            case .keychainSaveFailed(let status):
                return "Could not save signing key to Keychain (\(status))."
            case .secureEnclaveUnavailable:
                return "Secure Enclave is unavailable on this device."
            case .secureEnclaveAccessControlFailed:
                return "Could not create Secure Enclave access control."
            case .signingKeyUnavailable:
                return "Could not create a signing key."
            case .unsupportedCommand(let command):
                return "Unsupported secure command: \(command)"
            }
        }
    }

    private enum SigningIdentity {
        case secureEnclave(SecureEnclave.P256.Signing.PrivateKey)
        case software(P256.Signing.PrivateKey)

        var publicKeyX963Representation: Data {
            switch self {
            case .secureEnclave(let key):
                return key.publicKey.x963Representation
            case .software(let key):
                return key.publicKey.x963Representation
            }
        }

        func signature(for data: Data) throws -> Data {
            switch self {
            case .secureEnclave(let key):
                return try key.signature(for: data).rawRepresentation
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

    private static let keychainService = "DoorUnlocker.SigningIdentity"
    private static let secureEnclaveAccount = "secure-enclave-p256"
    private static let softwareAccount = "software-p256"
    private static let cache = AuthCache()

    static func prewarm() {
        guard let identity = try? identity() else { return }
        _ = try? fastCommandKeyFingerprint(for: identity)
        _ = try? identity.signature(for: DoorSecureCommandCodec.signatureDomain)
    }

    static func publicKeyForPairing() throws -> Data {
        try identity().publicKeyX963Representation
    }

    static func pairingPayload(deviceName: String) throws -> Data {
        try DoorSecureCommandCodec.pairingPayload(
            publicKey: publicKeyForPairing(),
            deviceName: deviceName,
            fallbackName: "iPhone"
        )
    }

    static func pairingApprovalCode() throws -> String {
        try DoorSecureCommandCodec.approvalCode(publicKey: publicKeyForPairing())
    }

    static func fastCommandPayload(for command: DoorUnlockerController.Command, nonce: Data) throws -> SignedFastCommandPayload {
        let secureCommand: DoorSecureCommandCodec.FastCommand = command == .unlock ? .unlock : .lock
        let encodedCommand = DoorSecureCommandCodec.encodedFastCommand(secureCommand)
        return try v3CommandPayload(encodedCommand, nonce: nonce)
    }

    static func secureCommandPayload(for commandText: String, nonce: Data) throws -> SignedFastCommandPayload {
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
        defer { cache.lock.unlock() }

        if let identity = cache.identity {
            return identity
        }

        let resolvedIdentity = try loadIdentity()
        cache.identity = resolvedIdentity
        return resolvedIdentity
    }

    private static func loadIdentity() throws -> SigningIdentity {
        if let data = try readKeychainData(account: secureEnclaveAccount) {
            if let key = try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: data) {
                return .secureEnclave(key)
            }
            deleteKeychainData(account: secureEnclaveAccount)
        }

        if let data = try readKeychainData(account: softwareAccount) {
            if let key = try? P256.Signing.PrivateKey(rawRepresentation: data) {
                return .software(key)
            }
            deleteKeychainData(account: softwareAccount)
        }

        if let secureEnclaveKey = try? createSecureEnclaveKey() {
            try saveKeychainData(secureEnclaveKey.dataRepresentation, account: secureEnclaveAccount)
            return .secureEnclave(secureEnclaveKey)
        }

        let softwareKey = P256.Signing.PrivateKey()
        try saveKeychainData(softwareKey.rawRepresentation, account: softwareAccount)
        return .software(softwareKey)
    }

    private static func createSecureEnclaveKey() throws -> SecureEnclave.P256.Signing.PrivateKey {
        #if targetEnvironment(simulator)
        throw AuthError.secureEnclaveUnavailable
        #else
        guard SecureEnclave.isAvailable else {
            throw AuthError.secureEnclaveUnavailable
        }

        var accessError: Unmanaged<CFError>?
        guard let accessControl = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.privateKeyUsage],
            &accessError
        ) else {
            throw AuthError.secureEnclaveAccessControlFailed
        }

        return try SecureEnclave.P256.Signing.PrivateKey(accessControl: accessControl)
        #endif
    }

    private static func readKeychainData(account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw AuthError.keychainReadFailed(status)
        }

        return item as? Data
    }

    private static func saveKeychainData(_ data: Data, account: String) throws {
        deleteKeychainData(account: account)

        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data
        ]

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw AuthError.keychainSaveFailed(status)
        }
    }

    private static func deleteKeychainData(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account
        ]

        SecItemDelete(query as CFDictionary)
    }

}
