import Foundation
import XCTest
@testable import DoorUnlockerShared

final class DoorSecureNonceAcceptancePolicyTests: XCTestCase {
    func testRejectsDuplicateOfConsumedNonce() {
        let nonce = Data(repeating: 0x2A, count: 16)
        XCTAssertFalse(
            DoorSecureNonceAcceptancePolicy.shouldAccept(
                receivedNonce: nonce,
                lastConsumedNonce: nonce
            )
        )
    }

    func testAcceptsFreshOrFirstNonce() {
        let fresh = Data(repeating: 0x2B, count: 16)
        XCTAssertTrue(
            DoorSecureNonceAcceptancePolicy.shouldAccept(
                receivedNonce: fresh,
                lastConsumedNonce: Data(repeating: 0x2A, count: 16)
            )
        )
        XCTAssertTrue(
            DoorSecureNonceAcceptancePolicy.shouldAccept(
                receivedNonce: fresh,
                lastConsumedNonce: nil
            )
        )
    }
}
