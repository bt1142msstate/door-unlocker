import XCTest
@testable import DoorUnlockerShared

final class DoorFirmwareRecoveryIdentityTests: XCTestCase {
    func testRecognizesNormalControllerByServiceOrExactProductFamilyName() {
        XCTAssertTrue(DoorFirmwareRecoveryIdentity.isNormalController(name: nil, advertisesControllerService: true))
        XCTAssertTrue(
            DoorFirmwareRecoveryIdentity.isNormalController(
                name: "DoorUnlocker-XIAO-v4",
                advertisesControllerService: false
            )
        )
    }

    func testDoesNotMisclassifyBootloaderOrUnrelatedPeripheral() {
        XCTAssertFalse(DoorFirmwareRecoveryIdentity.isNormalController(name: "AdaDFU", advertisesControllerService: false))
        XCTAssertFalse(
            DoorFirmwareRecoveryIdentity.isNormalController(
                name: "DoorUnlocker-XIAO-DFU",
                advertisesControllerService: false
            )
        )
        XCTAssertFalse(DoorFirmwareRecoveryIdentity.isNormalController(name: "Headphones", advertisesControllerService: false))
    }
}
