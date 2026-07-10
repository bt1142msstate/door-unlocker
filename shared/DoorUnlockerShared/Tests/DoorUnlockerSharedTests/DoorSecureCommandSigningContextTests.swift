import XCTest
@testable import DoorUnlockerShared

final class DoorSecureCommandSigningContextTests: XCTestCase {
    private let publicKey = Data((0..<65).map(UInt8.init))

    func testPairingValuesUseOneCachedPublicKeyContext() {
        let context = DoorSecureCommandSigningContext(publicKey: publicKey)

        XCTAssertEqual(
            context.pairingPayload(deviceName: "Brandon's iPhone", fallbackName: "iPhone"),
            DoorSecureCommandCodec.pairingPayload(
                publicKey: publicKey,
                deviceName: "Brandon's iPhone",
                fallbackName: "iPhone"
            )
        )
        XCTAssertEqual(context.pairingApprovalCode, DoorSecureCommandCodec.approvalCode(publicKey: publicKey))
        XCTAssertEqual(context.keyFingerprint, DoorSecureCommandCodec.keyFingerprint(publicKey: publicKey))
    }

    func testFastCommandBuildsTheCompleteSignedWirePacket() throws {
        let context = DoorSecureCommandSigningContext(publicKey: publicKey)
        let nonce = Data(repeating: 0x5a, count: DoorSecureCommandCodec.nonceLength)
        var messagePassedToSigner: Data?

        let packet = try context.signedFastCommand(.unlock, nonce: nonce) { message in
            messagePassedToSigner = message
            return Data(repeating: 0xa5, count: 64)
        }

        XCTAssertEqual(packet[0], DoorSecureCommandCodec.fastCommandVersion)
        XCTAssertEqual(packet[1], DoorSecureCommandCodec.fastCommandUnlockOp)
        XCTAssertEqual(
            packet[2..<(2 + DoorSecureCommandCodec.keyFingerprintLength)],
            context.keyFingerprint[...]
        )
        XCTAssertEqual(messagePassedToSigner, DoorSecureCommandCodec.messageToSign(
            unsignedPacket: packet.dropLast(64)
        ))
        XCTAssertEqual(packet.suffix(64), Data(repeating: 0xa5, count: 64))
    }

    func testTextCommandUsesSharedEncodingBeforeSigning() throws {
        let context = DoorSecureCommandSigningContext(publicKey: publicKey)
        let nonce = Data(repeating: 0x3c, count: DoorSecureCommandCodec.nonceLength)

        let packet = try context.signedCommand(commandText: "SET_TIMEOUT:30", nonce: nonce) { _ in
            Data(repeating: 0x11, count: 64)
        }
        let payloadLengthIndex = 2 + DoorSecureCommandCodec.keyFingerprintLength + DoorSecureCommandCodec.nonceLength

        XCTAssertEqual(packet[1], DoorSecureCommandCodec.fastCommandSetTimeoutOp)
        XCTAssertEqual(packet[payloadLengthIndex], 2)
        XCTAssertEqual(Array(packet[(payloadLengthIndex + 1)...(payloadLengthIndex + 2)]), [0, 30])
    }

    func testInvalidNonceFailsBeforeCallingSigner() {
        let context = DoorSecureCommandSigningContext(publicKey: publicKey)
        var signerWasCalled = false

        XCTAssertThrowsError(try context.signedFastCommand(.lock, nonce: Data()) { _ in
            signerWasCalled = true
            return Data(repeating: 0, count: 64)
        })
        XCTAssertFalse(signerWasCalled)
    }
}
