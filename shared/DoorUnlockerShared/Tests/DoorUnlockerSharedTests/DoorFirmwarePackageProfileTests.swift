import XCTest
@testable import DoorUnlockerShared

final class DoorFirmwarePackageProfileTests: XCTestCase {
    func testFreshAdvertisementOverridesCachedFactoryBootloaderName() {
        let name = DoorFirmwarePackageProfile.resolvedBootloaderName(
            advertisedLocalName: "DoorDFU",
            cachedPeripheralName: "AdaDFU"
        )

        XCTAssertEqual(name, "DoorDFU")
        XCTAssertEqual(
            DoorFirmwarePackageProfile.select(forBootloaderNamed: name),
            .signed
        )
    }

    func testCachedNameIsFallbackWhenAdvertisementOmitsName() {
        XCTAssertEqual(
            DoorFirmwarePackageProfile.resolvedBootloaderName(
                advertisedLocalName: nil,
                cachedPeripheralName: "AdaDFU"
            ),
            "AdaDFU"
        )
    }

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
