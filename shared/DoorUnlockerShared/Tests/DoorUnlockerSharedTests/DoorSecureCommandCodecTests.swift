import XCTest
@testable import DoorUnlockerShared

final class DoorSecureCommandCodecTests: XCTestCase {
    func testBuildsPairingPayloadWithNormalizedName() {
        let publicKey = Data(repeating: 0x42, count: 65)

        let payload = DoorSecureCommandCodec.pairingPayload(
            publicKey: publicKey,
            deviceName: "Brandon's\nPhone",
            fallbackName: "iPhone"
        )

        XCTAssertEqual(payload.first, DoorSecureCommandCodec.pairingPayloadWithNameVersion)
        XCTAssertEqual(payload.dropFirst().prefix(publicKey.count), publicKey[...])
        XCTAssertEqual(String(data: payload.dropFirst(1 + publicKey.count), encoding: .utf8), "Brandon's Phone")
    }

    func testApprovalCodeUsesFirstTwoDigestBytesModulo10000() {
        let publicKey = Data("test-public-key".utf8)

        XCTAssertEqual(DoorSecureCommandCodec.approvalCode(publicKey: publicKey), "1342")
    }

    func testEncodesReadAndWriteCommands() throws {
        XCTAssertEqual(
            try DoorSecureCommandCodec.encodedCommand(commandText: "GET_LOCK_NAME"),
            .init(op: DoorSecureCommandCodec.fastCommandGetLockNameOp, payload: Data())
        )
        XCTAssertEqual(
            try DoorSecureCommandCodec.encodedCommand(commandText: "SET_TIMEOUT:30"),
            .init(op: DoorSecureCommandCodec.fastCommandSetTimeoutOp, payload: Data([0x00, 0x1e]))
        )
        XCTAssertEqual(
            try DoorSecureCommandCodec.encodedCommand(commandText: "SET_ANGLES:20,95"),
            .init(op: DoorSecureCommandCodec.fastCommandSetServoAnglesOp, payload: Data([20, 95]))
        )
        XCTAssertEqual(
            try DoorSecureCommandCodec.encodedCommand(commandText: "SET_NAME:My\u{2019}s Phone").payload,
            Data("My's Phone".utf8)
        )
        XCTAssertEqual(
            try DoorSecureCommandCodec.encodedCommand(commandText: "PAIR_ON"),
            .init(op: DoorSecureCommandCodec.fastCommandPairingEnableOp, payload: Data())
        )
        XCTAssertEqual(
            try DoorSecureCommandCodec.encodedCommand(commandText: "PAIR_OFF"),
            .init(op: DoorSecureCommandCodec.fastCommandPairingDisableOp, payload: Data())
        )
        XCTAssertEqual(
            try DoorSecureCommandCodec.encodedCommand(commandText: "PAIR_APPROVE: 1234 "),
            .init(op: DoorSecureCommandCodec.fastCommandPairingApproveOp, payload: Data("1234".utf8))
        )
        XCTAssertEqual(
            try DoorSecureCommandCodec.encodedCommand(commandText: "PAIR_REJECT"),
            .init(op: DoorSecureCommandCodec.fastCommandPairingRejectOp, payload: Data())
        )
    }

    func testBuildsUnsignedPacketAndMessageToSign() throws {
        let nonce = Data(0..<16)
        let fingerprint = Data([0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x11, 0x22])

        let packet = try DoorSecureCommandCodec.unsignedPacket(
            op: DoorSecureCommandCodec.fastCommandUnlockOp,
            payload: Data([0x99]),
            nonce: nonce,
            keyFingerprint: fingerprint
        )

        XCTAssertEqual(packet.prefix(2), Data([DoorSecureCommandCodec.fastCommandVersion, DoorSecureCommandCodec.fastCommandUnlockOp]))
        XCTAssertEqual(packet.dropFirst(2).prefix(8), fingerprint[...])
        XCTAssertEqual(packet.dropFirst(10).prefix(16), nonce[...])
        XCTAssertEqual(packet.dropFirst(26), Data([0x01, 0x99]))

        let signedMessage = DoorSecureCommandCodec.messageToSign(unsignedPacket: packet)
        XCTAssertTrue(signedMessage.starts(with: DoorSecureCommandCodec.signatureDomain))
        XCTAssertEqual(signedMessage.dropFirst(DoorSecureCommandCodec.signatureDomain.count), packet[...])
    }

    func testRejectsInvalidNonceAndPayloadLength() {
        XCTAssertThrowsError(try DoorSecureCommandCodec.unsignedPacket(
            op: DoorSecureCommandCodec.fastCommandUnlockOp,
            payload: Data(),
            nonce: Data(repeating: 0, count: 15),
            keyFingerprint: Data(repeating: 0, count: 8)
        ))

        XCTAssertThrowsError(try DoorSecureCommandCodec.unsignedPacket(
            op: DoorSecureCommandCodec.fastCommandUnlockOp,
            payload: Data(repeating: 0, count: DoorSecureCommandCodec.maxPayloadLength + 1),
            nonce: Data(repeating: 0, count: DoorSecureCommandCodec.nonceLength),
            keyFingerprint: Data(repeating: 0, count: 8)
        ))
    }
}
