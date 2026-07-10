import DoorUnlockerShared
import XCTest
@testable import DoorUnlocker

final class DoorCommandAuthenticatorParityTests: XCTestCase {
    func testFastCommandWrappersUseSharedWireOpcodes() throws {
        let nonce = Data(repeating: 0x5a, count: DoorSecureCommandCodec.nonceLength)
        let unlock = try DoorCommandAuthenticator.fastCommandPayload(for: .unlock, nonce: nonce).data
        let lock = try DoorCommandAuthenticator.fastCommandPayload(for: .lock, nonce: nonce).data

        assertSignedPacket(unlock, opcode: DoorSecureCommandCodec.fastCommandUnlockOp, nonce: nonce)
        assertSignedPacket(lock, opcode: DoorSecureCommandCodec.fastCommandLockOp, nonce: nonce)
    }

    func testSecureSettingWrapperUsesSharedWireOpcodeAndPayload() throws {
        let nonce = Data(repeating: 0x3c, count: DoorSecureCommandCodec.nonceLength)
        let packet = try DoorCommandAuthenticator.secureCommandPayload(
            for: "SET_TIMEOUT:30",
            nonce: nonce
        ).data

        assertSignedPacket(packet, opcode: DoorSecureCommandCodec.fastCommandSetTimeoutOp, nonce: nonce)
        let payloadLengthIndex = 2 + DoorSecureCommandCodec.keyFingerprintLength + DoorSecureCommandCodec.nonceLength
        XCTAssertEqual(packet[payloadLengthIndex], 2)
        XCTAssertEqual(Array(packet[(payloadLengthIndex + 1)...(payloadLengthIndex + 2)]), [0, 30])
    }

    private func assertSignedPacket(_ packet: Data, opcode: UInt8, nonce: Data) {
        XCTAssertEqual(packet[0], DoorSecureCommandCodec.fastCommandVersion)
        XCTAssertEqual(packet[1], opcode)
        let nonceStart = 2 + DoorSecureCommandCodec.keyFingerprintLength
        XCTAssertEqual(packet[nonceStart..<(nonceStart + nonce.count)], nonce[...])
        XCTAssertEqual(packet.count, 2 + 8 + 16 + 1 + Int(packet[26]) + 64)
    }
}
