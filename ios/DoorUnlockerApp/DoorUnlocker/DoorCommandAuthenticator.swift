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
        var signingContext: DoorSecureCommandSigningContext?
    }

    private static let keychainService = "DoorUnlocker.SigningIdentity"
    // v2 keys are accessible after the first device unlock so background BLE
    // restoration can sign without rotating identity while the screen is locked.
    private static let secureEnclaveAccount = "secure-enclave-p256-v2"
    private static let softwareAccount = "software-p256-v2"
    private static let cache = AuthCache()

    static func prewarm() {
        guard let identity = try? identity() else { return }
        _ = signingContext(for: identity)
        _ = try? identity.signature(for: DoorSecureCommandCodec.signatureDomain)
    }

    static func publicKeyForPairing() throws -> Data {
        try identity().publicKeyX963Representation
    }

    static func pairingPayload(deviceName: String) throws -> Data {
        let identity = try identity()
        return signingContext(for: identity).pairingPayload(
            deviceName: deviceName,
            fallbackName: "iPhone"
        )
    }

    static func pairingApprovalCode() throws -> String {
        let identity = try identity()
        return signingContext(for: identity).pairingApprovalCode
    }

    static func fastCommandPayload(for command: DoorCommand, nonce: Data) throws -> SignedFastCommandPayload {
        let encodedCommand = DoorSecureCommandCodec.encodedFastCommand(command)
        return try v3CommandPayload(encodedCommand, nonce: nonce)
    }

    static func secureCommandPayload(for commandText: String, nonce: Data) throws -> SignedFastCommandPayload {
        let encodedCommand = try DoorSecureCommandCodec.encodedCommand(commandText: commandText)
        return try v3CommandPayload(encodedCommand, nonce: nonce)
    }

    private static func v3CommandPayload(_ encodedCommand: DoorSecureCommandCodec.EncodedCommand, nonce: Data) throws -> SignedFastCommandPayload {
        let identity = try identity()
        return SignedFastCommandPayload(
            data: try signingContext(for: identity).signedPacket(
                encodedCommand,
                nonce: nonce,
                signer: identity.signature
            )
        )
    }

    private static func signingContext(for identity: SigningIdentity) -> DoorSecureCommandSigningContext {
        cache.lock.lock()
        if let signingContext = cache.signingContext {
            cache.lock.unlock()
            return signingContext
        }
        cache.lock.unlock()

        let signingContext = DoorSecureCommandSigningContext(
            publicKey: identity.publicKeyX963Representation
        )

        cache.lock.lock()
        cache.signingContext = signingContext
        cache.lock.unlock()

        return signingContext
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
            do {
                let key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: data)
                return .secureEnclave(key)
            } catch {
                // A locked device or temporarily unavailable Secure Enclave is
                // not evidence of corruption. Never delete or replace identity.
                throw AuthError.signingKeyUnavailable
            }
        }

        if let data = try readKeychainData(account: softwareAccount) {
            do {
                let key = try P256.Signing.PrivateKey(rawRepresentation: data)
                return .software(key)
            } catch {
                throw AuthError.signingKeyUnavailable
            }
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
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
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
