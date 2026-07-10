import XCTest
@testable import DoorUnlockerShared

final class DoorCommandPreparationRecoveryPolicyTests: XCTestCase {
    func testIdleWhenFreshNonceIsNotNeeded() {
        XCTAssertEqual(
            DoorCommandPreparationRecoveryPolicy.action(
                needsFreshNonce: false,
                hasQueuedCommand: true,
                completedNonceRequests: 99
            ),
            .idle
        )
    }

    func testBackgroundPreparationKeepsRequestingWithoutQueuedCommand() {
        XCTAssertEqual(
            DoorCommandPreparationRecoveryPolicy.action(
                needsFreshNonce: true,
                hasQueuedCommand: false,
                completedNonceRequests: 99
            ),
            .requestNonce
        )
    }

    func testQueuedCommandRequestsNonceUntilLimit() {
        for completedRequests in 0..<DoorCommandPreparationRecoveryPolicy.defaultMaximumNonceRequests {
            XCTAssertEqual(
                DoorCommandPreparationRecoveryPolicy.action(
                    needsFreshNonce: true,
                    hasQueuedCommand: true,
                    completedNonceRequests: completedRequests
                ),
                .requestNonce
            )
        }
    }

    func testQueuedCommandReconnectsAtLimit() {
        XCTAssertEqual(
            DoorCommandPreparationRecoveryPolicy.action(
                needsFreshNonce: true,
                hasQueuedCommand: true,
                completedNonceRequests: DoorCommandPreparationRecoveryPolicy.defaultMaximumNonceRequests
            ),
            .reconnect
        )
    }
}
