import XCTest
@testable import DoorUnlockerShared

final class DoorFirmwareUpdatePolicyTests: XCTestCase {
    func testInstallsBundledFirmwareOnlyWhenBundledVersionIsNewer() {
        XCTAssertTrue(DoorFirmwareUpdatePolicy.shouldInstallBundledFirmware(
            installedVersion: "0.1.0",
            bundledVersion: "0.1.1"
        ))

        XCTAssertFalse(DoorFirmwareUpdatePolicy.shouldInstallBundledFirmware(
            installedVersion: "0.1.1",
            bundledVersion: "0.1.1"
        ))

        XCTAssertFalse(DoorFirmwareUpdatePolicy.shouldInstallBundledFirmware(
            installedVersion: "0.1.2",
            bundledVersion: "0.1.1"
        ))
    }

    func testDoesNotDowngradeFromNewerBetaBuild() {
        XCTAssertEqual(
            DoorFirmwareUpdatePolicy.decision(
                installedVersion: "0.1.0-beta.ota28",
                bundledVersion: "0.1.0"
            ),
            .installedVersionIsNewer
        )
    }

    func testWaitsWhenInstalledVersionIsUnknown() {
        XCTAssertEqual(
            DoorFirmwareUpdatePolicy.decision(installedVersion: "Unknown", bundledVersion: "0.1.1"),
            .unknownInstalledVersion
        )
    }

    func testTreatsMissingBundledVersionAsNotInstallable() {
        XCTAssertEqual(
            DoorFirmwareUpdatePolicy.decision(installedVersion: "0.1.0", bundledVersion: nil),
            .missingBundledVersion
        )
    }
}
