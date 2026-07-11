import XCTest
@testable import DoorUnlockerShared

final class DoorSingleFlightRequestGateTests: XCTestCase {
    func testOnlyOneRequestMayBeInFlight() {
        var gate = DoorSingleFlightRequestGate()
        let generation = gate.begin(at: 10, minimumInterval: 0.2)

        XCTAssertNotNil(generation)
        XCTAssertNil(gate.begin(at: 11, minimumInterval: 0.2))
        XCTAssertTrue(gate.isInFlight)
    }

    func testCompletionRetainsMinimumIntervalAndInvalidationClearsIt() {
        var gate = DoorSingleFlightRequestGate()
        XCTAssertNotNil(gate.begin(at: 10, minimumInterval: 0.2))
        gate.complete()
        XCTAssertNil(gate.begin(at: 10.1, minimumInterval: 0.2))
        XCTAssertNotNil(gate.begin(at: 10.2, minimumInterval: 0.2))

        gate.invalidate()
        XCTAssertNotNil(gate.begin(at: 0, minimumInterval: 0.2))
    }

    func testOldTimeoutCannotExpireNewerRequest() {
        var gate = DoorSingleFlightRequestGate()
        let first = try! XCTUnwrap(gate.begin(at: 1, minimumInterval: 0))
        gate.complete()
        let second = try! XCTUnwrap(gate.begin(at: 2, minimumInterval: 0))

        XCTAssertFalse(gate.expire(generation: first))
        XCTAssertTrue(gate.isInFlight)
        XCTAssertTrue(gate.expire(generation: second))
        XCTAssertFalse(gate.isInFlight)
    }
}
