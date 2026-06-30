import CryptoKit
import Foundation
import Security

enum DoorCommandAuthenticator {
    private static let counterKey = "SecureDoorCommandCounter"
    // Public sample key. Replace with a private 32-byte key and paste the same
    // bytes into DoorUnlockerXiao.ino before real hardware use.
    private static let keyBytes: [UInt8] = [
        0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
        0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
        0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17,
        0x18, 0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f
    ]

    static func payload(for command: DoorUnlockerController.Command) -> Data {
        let counter = nextCounter()
        let message = "v1|\(counter)|\(command.rawValue)"
        let key = SymmetricKey(data: keyBytes)
        let signature = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)
        let mac = signature.map { String(format: "%02x", $0) }.joined()
        return Data("\(message)|\(mac)".utf8)
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
