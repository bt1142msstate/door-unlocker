import XCTest
@testable import DoorUnlockerShared

final class DoorFirmwareRecoveryScanPolicyTests: XCTestCase {
    func testEveryRoleAndModeCombinationUsesOneDeterministicAction() {
        let roles: [DoorFirmwareRecoveryPeripheralRole] = [
            .normalController,
            .bootloader,
            .unrelated
        ]

        for role in roles {
            for detectsNormal in [false, true] {
                for allowsUpload in [false, true] {
                    let expected: DoorFirmwareRecoveryScanAction
                    switch role {
                    case .normalController:
                        expected = detectsNormal ? .notifyNormalController : .ignore
                    case .bootloader:
                        expected = (!detectsNormal || allowsUpload) ? .startBootloaderUpload : .ignore
                    case .unrelated:
                        expected = .ignore
                    }

                    XCTAssertEqual(
                        DoorFirmwareRecoveryScanPolicy.action(
                            role: role,
                            detectsNormalControllerFirmware: detectsNormal,
                            allowsBootloaderUpload: allowsUpload
                        ),
                        expected,
                        "Unexpected action for role=\(role), detectsNormal=\(detectsNormal), allowsUpload=\(allowsUpload)"
                    )
                }
            }
        }
    }
}
