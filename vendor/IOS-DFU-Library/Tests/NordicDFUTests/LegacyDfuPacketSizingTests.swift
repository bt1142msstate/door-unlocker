import XCTest
@testable import NordicDFU

final class LegacyDfuPacketSizingTests: XCTestCase {
    func testPreservesTwentyByteFallbackForUnknownBootloaders() {
        XCTAssertEqual(
            LegacyDfuPacketSizing.payloadBytes(
                maximumWriteValueLength: 244,
                peripheralName: "UnknownDFU"
            ),
            20
        )
        XCTAssertEqual(
            LegacyDfuPacketSizing.payloadBytes(
                maximumWriteValueLength: 244,
                peripheralName: nil
            ),
            20
        )
    }

    func testUsesMeasuredNegotiatedPayloadForFactoryBootloader() {
        XCTAssertEqual(
            LegacyDfuPacketSizing.payloadBytes(
                maximumWriteValueLength: 244,
                peripheralName: "AdaDFU"
            ),
            244
        )
    }

    func testUsesNegotiatedPayloadForDoorUnlockerBootloader() {
        XCTAssertEqual(
            LegacyDfuPacketSizing.payloadBytes(
                maximumWriteValueLength: 182,
                peripheralName: "DoorDFU"
            ),
            182
        )
    }

    func testUsesNegotiatedPayloadForStableDoorUnlockerBootloader() {
        XCTAssertEqual(
            LegacyDfuPacketSizing.payloadBytes(
                maximumWriteValueLength: 244,
                peripheralName: "DoorDFUStable"
            ),
            244
        )
    }

    func testCapsPayloadAtBootloaderMaximum() {
        XCTAssertEqual(
            LegacyDfuPacketSizing.payloadBytes(
                maximumWriteValueLength: 512,
                peripheralName: "DoorDFU"
            ),
            244
        )
    }
}
