import XCTest
@testable import DoorUnlockerShared

final class DoorFastWritePolicyTests: XCTestCase {
    func testSendsImmediatelyWhenTransportCanAcceptPayload() {
        XCTAssertEqual(
            DoorFastWritePolicy.action(
                supportsWriteWithoutResponse: true,
                payloadFits: true,
                canSendWriteWithoutResponse: true
            ),
            .sendNow
        )
    }

    func testWaitsWithoutConsumingSecureMaterialWhenTransportIsBackpressured() {
        XCTAssertEqual(
            DoorFastWritePolicy.action(
                supportsWriteWithoutResponse: true,
                payloadFits: true,
                canSendWriteWithoutResponse: false
            ),
            .waitForCapacity
        )
    }

    func testRejectsUnsupportedOrOversizedFastWrites() {
        XCTAssertEqual(
            DoorFastWritePolicy.action(
                supportsWriteWithoutResponse: false,
                payloadFits: true,
                canSendWriteWithoutResponse: true
            ),
            .unsupported
        )
        XCTAssertEqual(
            DoorFastWritePolicy.action(
                supportsWriteWithoutResponse: true,
                payloadFits: false,
                canSendWriteWithoutResponse: true
            ),
            .unsupported
        )
    }

    func testReliableWritesPreferAcknowledgedTransport() {
        XCTAssertEqual(
            DoorReliableWritePolicy.action(
                supportsWriteWithResponse: true,
                supportsWriteWithoutResponse: true,
                canSendWriteWithoutResponse: true
            ),
            .writeWithResponse
        )
    }

    func testReliableWritesFallBackToAvailableUnacknowledgedTransport() {
        XCTAssertEqual(
            DoorReliableWritePolicy.action(
                supportsWriteWithResponse: false,
                supportsWriteWithoutResponse: true,
                canSendWriteWithoutResponse: true
            ),
            .writeWithoutResponse
        )
    }

    func testReliableWritesDoNotDispatchIntoBackpressure() {
        XCTAssertEqual(
            DoorReliableWritePolicy.action(
                supportsWriteWithResponse: false,
                supportsWriteWithoutResponse: true,
                canSendWriteWithoutResponse: false
            ),
            .unsupported
        )
    }
}
