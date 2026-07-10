import XCTest
@testable import DoorUnlockerShared

final class DoorCommandTests: XCTestCase {
    func testTransitionStateAndTargetMatchCommand() {
        XCTAssertEqual(DoorCommand.unlock.transitionState, "unlocking")
        XCTAssertTrue(DoorCommand.unlock.targetIsUnlocked)
        XCTAssertEqual(DoorCommand.lock.transitionState, "locking")
        XCTAssertFalse(DoorCommand.lock.targetIsUnlocked)
    }

    func testWireTextAndInverseAreStable() {
        XCTAssertEqual(DoorCommand.unlock.commandText, "UNLOCK")
        XCTAssertEqual(DoorCommand.lock.commandText, "LOCK")
        XCTAssertEqual(DoorCommand.unlock.inverse, .lock)
        XCTAssertEqual(DoorCommand.lock.inverse, .unlock)
    }

    func testPreparationPrioritizesPendingCommand() {
        XCTAssertEqual(
            DoorCommand.preparationOrder(preferred: .lock, isUnlocked: false),
            [.lock, .unlock]
        )
    }

    func testPreparationDefaultsToNextLogicalAction() {
        XCTAssertEqual(DoorCommand.preparationOrder(preferred: nil, isUnlocked: false), [.unlock, .lock])
        XCTAssertEqual(DoorCommand.preparationOrder(preferred: nil, isUnlocked: true), [.lock, .unlock])
    }
}
