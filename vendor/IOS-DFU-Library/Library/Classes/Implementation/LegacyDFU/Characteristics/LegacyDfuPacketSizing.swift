enum LegacyDfuPacketSizing {
    static let legacyPayloadBytes = 20
    static let adafruitMaximumPayloadBytes = 244

    static func payloadBytes(maximumWriteValueLength: Int) -> UInt32 {
        UInt32(
            max(
                legacyPayloadBytes,
                min(adafruitMaximumPayloadBytes, maximumWriteValueLength)
            )
        )
    }
}
