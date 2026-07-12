import XCTest
@testable import NordicDFU

final class LegacyDfuPacketSizingTests: XCTestCase {
    func testPreservesLegacyTwentyByteFallback() {
        XCTAssertEqual(LegacyDfuPacketSizing.payloadBytes(maximumWriteValueLength: 0), 20)
        XCTAssertEqual(LegacyDfuPacketSizing.payloadBytes(maximumWriteValueLength: 20), 20)
    }

    func testUsesNegotiatedAdafruitPayload() {
        XCTAssertEqual(LegacyDfuPacketSizing.payloadBytes(maximumWriteValueLength: 182), 182)
    }

    func testCapsPayloadAtBootloaderMaximum() {
        XCTAssertEqual(LegacyDfuPacketSizing.payloadBytes(maximumWriteValueLength: 512), 244)
    }
}
