import XCTest
@testable import DoorUnlockerShared

final class DoorControllerSettingDelayTests: XCTestCase {
    func testCompletedDelayReturnsTrue() async {
        let completed = await DoorControllerSettingDelay.wait(nanoseconds: 1_000_000)

        XCTAssertTrue(completed)
    }

    func testCancelledDelayReturnsFalseWithoutWaitingForDeadline() async {
        let task = Task {
            await DoorControllerSettingDelay.wait(nanoseconds: 5_000_000_000)
        }

        task.cancel()
        let completed = await task.value

        XCTAssertFalse(completed)
    }

    func testSettingTimingKeepsRetrySlowerThanInputDebounce() {
        XCTAssertGreaterThan(
            DoorControllerSettingDelay.busyRetryNanoseconds,
            DoorControllerSettingDelay.inputDebounceNanoseconds
        )
    }
}
