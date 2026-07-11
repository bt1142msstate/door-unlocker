import XCTest
@testable import DoorUnlockerShared

final class DoorCommandConfirmationPolicyTests: XCTestCase {
    func testFallbackReadsAreSparseAndOrderedBeforeFailure() {
        let reads = DoorCommandConfirmationPolicy.fallbackReadDeadlines
        XCTAssertEqual(reads.count, 2)
        XCTAssertEqual(reads, reads.sorted())
        XCTAssertTrue(reads.allSatisfy { $0 < DoorCommandConfirmationPolicy.failureDeadline })
    }

    func testFirstFallbackLeavesNotificationFastPathUncontested() {
        XCTAssertGreaterThanOrEqual(
            DoorCommandConfirmationPolicy.fallbackReadDeadlines[0],
            .milliseconds(250)
        )
    }
}
