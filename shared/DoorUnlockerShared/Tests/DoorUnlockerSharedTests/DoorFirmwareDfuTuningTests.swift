import XCTest
@testable import DoorUnlockerShared

final class DoorFirmwareDfuTuningTests: XCTestCase {
    func testOptimizedBootloaderUsesPlatformReceiptWindow() {
        let tuning = DoorFirmwareDfuTuning(packetReceiptNotificationParameter: 8)

        XCTAssertEqual(
            tuning.packetReceiptNotificationParameter(forBootloaderNamed: "DoorDFU"),
            8
        )
        XCTAssertEqual(
            tuning.packetReceiptNotificationParameter(forBootloaderNamed: "AdaDFU"),
            8
        )
    }

    func testOptimizedBootloaderUsesSharedReceiptWindowOnMac() {
        let tuning = DoorFirmwareDfuTuning(
            packetReceiptNotificationParameter: DoorFirmwareDfuTuning.defaultMacPacketReceiptNotificationParameter
        )

        XCTAssertEqual(
            tuning.packetReceiptNotificationParameter(forBootloaderNamed: "DoorDFU"),
            9
        )
    }
    func testStableDefaultMatchesMeasuredSafePath() {
        XCTAssertEqual(DoorFirmwareDfuTuning.stableDefault.packetReceiptNotificationParameter, 9)
        XCTAssertEqual(DoorFirmwareDfuTuning.stableDefault.dataObjectPreparationDelay, 0.3)
        XCTAssertEqual(DoorFirmwareDfuTuning.stableDefault.scanTimeout, 18)
        XCTAssertEqual(DoorFirmwareDfuTuning.stableDefault.connectionTimeout, 20)
    }

    func testMacDefaultUsesMeasuredOptimizedBootloaderReceiptWindow() {
        let tuning = DoorFirmwareDfuTuning.from(
            arguments: ["DoorUnlocker"],
            environment: [:],
            defaultPacketReceiptNotificationParameter: DoorFirmwareDfuTuning.defaultMacPacketReceiptNotificationParameter
        )

        XCTAssertEqual(tuning.packetReceiptNotificationParameter, 9)
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
        XCTAssertNil(tuning.transportLossAtProgress)
    }

    func testParsesOneShotTransportLossFaultInjectionProgress() {
        let tuning = DoorFirmwareDfuTuning.from(
            arguments: ["DoorUnlocker", "--debug-dfu-transport-loss-progress", "37"],
            environment: [:]
        )

        XCTAssertEqual(tuning.transportLossAtProgress, 37)
        XCTAssertNil(DoorFirmwareDfuTuning(transportLossAtProgress: 0).transportLossAtProgress)
        XCTAssertNil(DoorFirmwareDfuTuning(transportLossAtProgress: 100).transportLossAtProgress)
    }

    func testClampsToCurrentBootloaderSafeRange() {
        let tuning = DoorFirmwareDfuTuning(
            packetReceiptNotificationParameter: 100,
            dataObjectPreparationDelay: 0,
            scanTimeout: 1,
            connectionTimeout: 120
        )

        XCTAssertEqual(tuning.packetReceiptNotificationParameter, 32)
        XCTAssertEqual(tuning.dataObjectPreparationDelay, 0.3)
        XCTAssertEqual(tuning.scanTimeout, 5)
        XCTAssertEqual(tuning.connectionTimeout, 60)
    }
}
