import XCTest
@testable import DoorUnlockerShared

final class DoorFirmwareTransportOwnershipTests: XCTestCase {
    func testPendingSecureEntryKeepsNormalControllerTransportAvailable() {
        XCTAssertFalse(
            DoorFirmwareTransportOwnership.isDfuTransportActive(
                isUpdateRunning: true,
                entryCommandSent: false,
                hasPendingPackage: true
            )
        )
    }

    func testDfuOwnsTransportAfterEntryOrDuringDirectRecovery() {
        XCTAssertTrue(
            DoorFirmwareTransportOwnership.isDfuTransportActive(
                isUpdateRunning: true,
                entryCommandSent: true,
                hasPendingPackage: true
            )
        )
        XCTAssertTrue(
            DoorFirmwareTransportOwnership.isDfuTransportActive(
                isUpdateRunning: true,
                entryCommandSent: false,
                hasPendingPackage: false
            )
        )
    }

    func testIdleUpdateNeverOwnsDfuTransport() {
        XCTAssertFalse(
            DoorFirmwareTransportOwnership.isDfuTransportActive(
                isUpdateRunning: false,
                entryCommandSent: true,
                hasPendingPackage: false
            )
        )
    }
}
