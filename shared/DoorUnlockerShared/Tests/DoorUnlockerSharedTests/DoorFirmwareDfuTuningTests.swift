import XCTest
@testable import DoorUnlockerShared

final class DoorFirmwareDfuTuningTests: XCTestCase {
    func testOptimizedBootloaderUsesPerPacketAcknowledgements() {
        let tuning = DoorFirmwareDfuTuning(packetReceiptNotificationParameter: 8)

        XCTAssertEqual(
            tuning.packetReceiptNotificationParameter(forBootloaderNamed: "DoorDFU"),
            1
        )
        XCTAssertEqual(
            tuning.packetReceiptNotificationParameter(forBootloaderNamed: "AdaDFU"),
            8
        )
    }
    func testStableDefaultMatchesMeasuredSafePath() {
        XCTAssertEqual(DoorFirmwareDfuTuning.stableDefault.packetReceiptNotificationParameter, 8)
        XCTAssertEqual(DoorFirmwareDfuTuning.stableDefault.dataObjectPreparationDelay, 0.4)
        XCTAssertEqual(DoorFirmwareDfuTuning.stableDefault.scanTimeout, 18)
        XCTAssertEqual(DoorFirmwareDfuTuning.stableDefault.connectionTimeout, 20)
    }

    func testBuildsBenchmarkLaunchArguments() {
        XCTAssertEqual(
            DoorFirmwareDfuTuning.benchmarkLaunchArguments(
                packetReceiptNotificationParameter: 8,
                dataObjectPreparationDelay: 0.3
            ),
            ["--debug-dfu-prn", "8", "--debug-dfu-object-delay", "0.3"]
        )
    }

    func testParsesBenchmarkArgumentsAndEnvironment() {
        let tuning = DoorFirmwareDfuTuning.from(
            arguments: ["DoorUnlocker", "--debug-dfu-prn=4", "--debug-dfu-object-delay", "0.3"],
            environment: [
                "DOOR_UNLOCKER_DFU_SCAN_TIMEOUT": "12",
                "DOOR_UNLOCKER_DFU_CONNECTION_TIMEOUT": "15"
            ]
        )

        XCTAssertEqual(tuning.packetReceiptNotificationParameter, 4)
        XCTAssertEqual(tuning.dataObjectPreparationDelay, 0.3)
        XCTAssertEqual(tuning.scanTimeout, 12)
        XCTAssertEqual(tuning.connectionTimeout, 15)
    }

    func testClampsToCurrentBootloaderSafeRange() {
        let tuning = DoorFirmwareDfuTuning(
            packetReceiptNotificationParameter: 30,
            dataObjectPreparationDelay: 0,
            scanTimeout: 1,
            connectionTimeout: 120
        )

        XCTAssertEqual(tuning.packetReceiptNotificationParameter, 8)
        XCTAssertEqual(tuning.dataObjectPreparationDelay, 0.3)
        XCTAssertEqual(tuning.scanTimeout, 5)
        XCTAssertEqual(tuning.connectionTimeout, 60)
    }
}
