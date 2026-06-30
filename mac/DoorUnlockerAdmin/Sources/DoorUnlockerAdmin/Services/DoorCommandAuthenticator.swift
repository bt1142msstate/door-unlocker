import CryptoKit
import Foundation
import Security

enum DoorCommandAuthenticator {
    enum AuthError: LocalizedError {
        case keychainReadFailed(OSStatus)
        case keychainSaveFailed(OSStatus)
        case secureEnclaveAccessControlFailed

        var errorDescription: String? {
            switch self {
            case .keychainReadFailed(let status):
                return "Could not read signing key from Keychain (\(status))."
            case .keychainSaveFailed(let status):
                return "Could not save signing key to Keychain (\(status))."
            case .secureEnclaveAccessControlFailed:
                return "Could not create Secure Enclave access control."
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

    private static let counterKey = "DoorUnlockerAdminSecureCommandCounter"
    private static let keychainService = "DoorUnlockerAdmin.SigningIdentity"
    private static let secureEnclaveAccount = "secure-enclave-p256"
    private static let softwareAccount = "software-p256"
    private static let pairingPayloadWithNameVersion: UInt8 = 0x01
    private static let maximumPairingDeviceNameLength = 24

    static func pairingPayload(deviceName: String) throws -> Data {
        var payload = Data([pairingPayloadWithNameVersion])
        payload.append(try identity().publicKeyX963Representation)
        payload.append(sanitizedDeviceNameData(deviceName))
        return payload
    }

    static func payload(for commandText: String) throws -> Data {
        let counter = nextCounter()
        let message = "v2|\(counter)|\(commandText)"
        let signature = try identity().signature(for: Data(message.utf8))
        let signatureHex = signature.map { String(format: "%02x", $0) }.joined()
        return Data("\(message)|\(signatureHex)".utf8)
    }

    private static func sanitizedDeviceNameData(_ name: String) -> Data {
        let trimmed = name
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = trimmed.isEmpty ? "Mac" : trimmed
        let ascii = fallback.unicodeScalars.map { scalar -> UInt8 in
            scalar.isASCII && scalar.value >= 32 && scalar.value <= 126 ? UInt8(scalar.value) : UInt8(ascii: "?")
        }
        return Data(ascii.prefix(maximumPairingDeviceNameLength))
    }

    private static func identity() throws -> SigningIdentity {
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
        guard SecureEnclave.isAvailable else {
            throw AuthError.secureEnclaveAccessControlFailed
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

    private static func nextCounter() -> UInt64 {
        let defaults = UserDefaults.standard
        let current = defaults.string(forKey: counterKey).flatMap(UInt64.init) ?? startingCounter()
        let next = current == UInt64.max ? startingCounter() : current + 1
        defaults.set(String(next), forKey: counterKey)
        return next
    }

    private static func startingCounter() -> UInt64 {
        var random = UInt16.random(in: .min ... .max)
        let status = withUnsafeMutableBytes(of: &random) { bytes in
            SecRandomCopyBytes(kSecRandomDefault, bytes.count, bytes.baseAddress!)
        }
        if status != errSecSuccess {
            random = UInt16.random(in: .min ... .max)
        }

        let milliseconds = UInt64(Date().timeIntervalSince1970 * 1000)
        return (milliseconds << 16) | UInt64(random)
    }
}
