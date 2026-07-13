import XCTest
@testable import DoorUnlockerShared

final class DoorFirmwarePackageProfileTests: XCTestCase {
    func testFactoryBootloadersUseFactoryCompatiblePackage() {
        XCTAssertEqual(
            DoorFirmwarePackageProfile.select(forBootloaderNamed: "AdaDFU"),
            .factoryCompatible
        )
        XCTAssertEqual(
            DoorFirmwarePackageProfile.select(forBootloaderNamed: nil),
            .factoryCompatible
        )
    }

    func testOptimizedBootloaderUsesSignedPackage() {
        XCTAssertEqual(
            DoorFirmwarePackageProfile.select(forBootloaderNamed: "DoorDFU"),
            .signed
        )
    }

    func testBootloaderNameMatchIsExact() {
        XCTAssertEqual(
            DoorFirmwarePackageProfile.select(forBootloaderNamed: "DoorDFU-test"),
            .factoryCompatible
        )
        XCTAssertEqual(
            DoorFirmwarePackageProfile.select(forBootloaderNamed: "doordfu"),
            .factoryCompatible
        )
    }
}
