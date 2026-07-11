import XCTest
@testable import DoorUnlockerShared

final class DoorRestoredConnectionPolicyTests: XCTestCase {
    func testConnectedRestoredTransportIsReusedAndValidated() {
        XCTAssertEqual(
            DoorRestoredConnectionPolicy.action(for: .connected),
            .reuseAndValidate
        )
    }

    func testIncompleteRestoredTransportWaitsOrConnects() {
        XCTAssertEqual(
            DoorRestoredConnectionPolicy.action(for: .connecting),
            .awaitConnection
        )
        XCTAssertEqual(
            DoorRestoredConnectionPolicy.action(for: .disconnected),
            .connect
        )
    }

    func testExpiredUnvalidatedConnectedTransportForcesCleanReconnect() {
        XCTAssertTrue(
            DoorRestoredConnectionPolicy.shouldForceCleanReconnect(
                validationExpired: true,
                receivedFreshBootSession: false,
                isTransportConnected: true
            )
        )
    }

    func testFreshSessionOrDisconnectedTransportDoesNotForceReconnect() {
        XCTAssertFalse(
            DoorRestoredConnectionPolicy.shouldForceCleanReconnect(
                validationExpired: true,
                receivedFreshBootSession: true,
                isTransportConnected: true
            )
        )
        XCTAssertFalse(
            DoorRestoredConnectionPolicy.shouldForceCleanReconnect(
                validationExpired: true,
                receivedFreshBootSession: false,
                isTransportConnected: false
            )
        )
    }
}
