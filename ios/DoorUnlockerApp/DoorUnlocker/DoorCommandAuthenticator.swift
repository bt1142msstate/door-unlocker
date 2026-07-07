import CryptoKit
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
    }

    private static let keychainService = "DoorUnlocker.SigningIdentity"
    private static let secureEnclaveAccount = "secure-enclave-p256"
    private static let softwareAccount = "software-p256"
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
    private static let fastCommandNonceLength = 16
    private static let fastCommandKeyFingerprintLength = 8
    private static let fastCommandMaxPayloadLength = 129
    private static let fastCommandSignatureDomain = Data("DoorUnlocker:v3:command".utf8)
    private static let cache = AuthCache()

    static func prewarm() {
        _ = try? identity()
    }

    static func publicKeyForPairing() throws -> Data {
        try identity().publicKeyX963Representation
    }

    static func pairingPayload(deviceName: String) throws -> Data {
        var payload = Data([pairingPayloadWithNameVersion])
        payload.append(try publicKeyForPairing())
        payload.append(sanitizedDeviceNameData(deviceName))
        return payload
    }

    static func pairingApprovalCode() throws -> String {
        try approvalCode(for: publicKeyForPairing())
    }

    static func fastCommandPayload(for command: DoorUnlockerController.Command, nonce: Data) throws -> SignedFastCommandPayload {
        let op: UInt8 = command == .unlock ? fastCommandUnlockOp : fastCommandLockOp
        return try v3CommandPayload(op: op, payload: Data(), nonce: nonce)
    }

    static func fastCommandPayloads(nonce: Data) throws -> [DoorUnlockerController.Command: SignedFastCommandPayload] {
        [
            .unlock: try fastCommandPayload(for: .unlock, nonce: nonce),
            .lock: try fastCommandPayload(for: .lock, nonce: nonce)
        ]
    }

    static func secureCommandPayload(for commandText: String, nonce: Data) throws -> SignedFastCommandPayload {
        let encodedCommand = try v3CommandEncoding(for: commandText)
        return try v3CommandPayload(op: encodedCommand.op, payload: encodedCommand.payload, nonce: nonce)
    }

    private static func v3CommandPayload(op: UInt8, payload: Data, nonce: Data) throws -> SignedFastCommandPayload {
        guard nonce.count == fastCommandNonceLength,
              payload.count <= fastCommandMaxPayloadLength else {
            throw AuthError.signingKeyUnavailable
        }

        let fingerprint = try fastCommandKeyFingerprint()
        var unsignedPacket = Data([fastCommandVersion, op])
        unsignedPacket.append(fingerprint)
        unsignedPacket.append(nonce)
        unsignedPacket.append(UInt8(payload.count))
        unsignedPacket.append(payload)

        var signedMessage = fastCommandSignatureDomain
        signedMessage.append(unsignedPacket)
        let signature = try identity().signature(for: signedMessage)

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
        let digest = SHA256.hash(data: try publicKeyForPairing())
        return Data(digest.prefix(fastCommandKeyFingerprintLength))
    }

    private static func approvalCode(for publicKey: Data) -> String {
        let digest = SHA256.hash(data: publicKey)
        let prefix = digest.prefix(2).reduce(UInt16(0)) { partialResult, byte in
            (partialResult << 8) | UInt16(byte)
        }
        return String(format: "%04u", prefix % 10_000)
    }

    private static func sanitizedDeviceNameData(_ name: String) -> Data {
        let normalized = name
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{201B}", with: "'")
            .replacingOccurrences(of: "\u{2032}", with: "'")
            .replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
            .replacingOccurrences(of: "\u{201E}", with: "\"")
            .replacingOccurrences(of: "\u{2033}", with: "\"")
            .replacingOccurrences(of: "\u{2010}", with: "-")
            .replacingOccurrences(of: "\u{2011}", with: "-")
            .replacingOccurrences(of: "\u{2012}", with: "-")
            .replacingOccurrences(of: "\u{2013}", with: "-")
            .replacingOccurrences(of: "\u{2014}", with: "-")
            .replacingOccurrences(of: "\u{2026}", with: "...")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = normalized.isEmpty ? "iPhone" : normalized
        let ascii = fallback.unicodeScalars.compactMap { scalar -> UInt8? in
            scalar.isASCII && scalar.value >= 32 && scalar.value <= 126 ? UInt8(scalar.value) : nil
        }
        return Data(ascii.prefix(maximumPairingDeviceNameLength))
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
