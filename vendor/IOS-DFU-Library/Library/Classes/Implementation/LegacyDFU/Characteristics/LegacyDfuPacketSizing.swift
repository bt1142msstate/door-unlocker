enum LegacyDfuPacketSizing {
    static let legacyPayloadBytes = 20
    static let adafruitMaximumPayloadBytes = 244
    static let optimizedBootloaderName = "DoorDFU"
    static let factoryBootloaderName = "AdaDFU"

    static func payloadBytes(
        maximumWriteValueLength: Int,
        peripheralName: String?
    ) -> UInt32 {
        guard peripheralName == optimizedBootloaderName || peripheralName == factoryBootloaderName else {
            return UInt32(legacyPayloadBytes)
        }
        return UInt32(
            max(
                legacyPayloadBytes,
                min(adafruitMaximumPayloadBytes, maximumWriteValueLength)
            )
        )
    }
}
