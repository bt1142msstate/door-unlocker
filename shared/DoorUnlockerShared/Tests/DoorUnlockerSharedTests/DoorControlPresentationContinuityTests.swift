import XCTest
@testable import DoorUnlockerShared

final class DoorControlPresentationContinuityTests: XCTestCase {
    func testColdStartDoesNotPretendControlWasEstablished() {
        var continuity = DoorControlPresentationContinuity()

        let effect = continuity.observe(
            isControlEstablished: false,
            isTransientConnection: true
        )

        XCTAssertEqual(effect, .none)
        XCTAssertFalse(continuity.isRetainingControl)
    }

    func testEstablishedControlIsRetainedAcrossShortConnectionTransition() {
        var continuity = DoorControlPresentationContinuity()
        _ = continuity.observe(isControlEstablished: true, isTransientConnection: false)

        let effect = continuity.observe(
            isControlEstablished: false,
            isTransientConnection: true
        )

        XCTAssertEqual(effect, .scheduleExpiration)
        XCTAssertTrue(continuity.isRetainingControl)
    }

    func testReadyConnectionCancelsPendingExpiration() {
        var continuity = DoorControlPresentationContinuity()
        _ = continuity.observe(isControlEstablished: true, isTransientConnection: false)
        _ = continuity.observe(isControlEstablished: false, isTransientConnection: true)

        let effect = continuity.observe(
            isControlEstablished: true,
            isTransientConnection: false
        )

        XCTAssertEqual(effect, .cancelExpiration)
        XCTAssertFalse(continuity.isRetainingControl)
        XCTAssertTrue(continuity.hasEstablishedControl)
    }

    func testExpirationRevealsSustainedConnectionState() {
        var continuity = DoorControlPresentationContinuity()
        _ = continuity.observe(isControlEstablished: true, isTransientConnection: false)
        _ = continuity.observe(isControlEstablished: false, isTransientConnection: true)

        continuity.expire()

        XCTAssertFalse(continuity.isRetainingControl)
        XCTAssertFalse(continuity.hasEstablishedControl)
    }
}
