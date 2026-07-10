import Foundation

public struct DoorSecureCommandSigningContext: Equatable, Sendable {
    public let publicKey: Data
    public let keyFingerprint: Data

    public init(publicKey: Data) {
        self.publicKey = publicKey
        self.keyFingerprint = DoorSecureCommandCodec.keyFingerprint(publicKey: publicKey)
    }

    public func pairingPayload(deviceName: String, fallbackName: String) -> Data {
        DoorSecureCommandCodec.pairingPayload(
            publicKey: publicKey,
            deviceName: deviceName,
            fallbackName: fallbackName
        )
    }

    public var pairingApprovalCode: String {
        DoorSecureCommandCodec.approvalCode(publicKey: publicKey)
    }

    public func signedFastCommand(
        _ command: DoorSecureCommandCodec.FastCommand,
        nonce: Data,
        signer: (Data) throws -> Data
    ) throws -> Data {
        try signedPacket(
            DoorSecureCommandCodec.encodedFastCommand(command),
            nonce: nonce,
            signer: signer
        )
    }

    public func signedCommand(
        commandText: String,
        nonce: Data,
        signer: (Data) throws -> Data
    ) throws -> Data {
        try signedPacket(
            DoorSecureCommandCodec.encodedCommand(commandText: commandText),
            nonce: nonce,
            signer: signer
        )
    }

    public func signedPacket(
        _ encodedCommand: DoorSecureCommandCodec.EncodedCommand,
        nonce: Data,
        signer: (Data) throws -> Data
    ) throws -> Data {
        let unsignedPacket = try DoorSecureCommandCodec.unsignedPacket(
            op: encodedCommand.op,
            payload: encodedCommand.payload,
            nonce: nonce,
            keyFingerprint: keyFingerprint
        )
        let signedMessage = DoorSecureCommandCodec.messageToSign(unsignedPacket: unsignedPacket)
        let signature = try signer(signedMessage)
        return DoorSecureCommandCodec.signedPacket(
            unsignedPacket: unsignedPacket,
            signature: signature
        )
    }
}
