import XCTest
@testable import DoorUnlockerShared

final class DoorFirmwareProgressEstimationTests: XCTestCase {
    func testUsesPackageSizeAndMeasuredThroughputWhenAvailable() {
        XCTAssertEqual(
            DoorFirmwareProgressEstimation.secondsRemaining(
                progress: 25,
                packageBytes: 100_000,
                averageBytesPerSecond: 10_000,
                elapsedUploadTime: 100
            ),
            8
        )
    }

    func testFallsBackToElapsedProgressWhenThroughputIsUnavailable() {
        XCTAssertEqual(
            DoorFirmwareProgressEstimation.secondsRemaining(
                progress: 40,
                packageBytes: 0,
                averageBytesPerSecond: 0,
                elapsedUploadTime: 4
            ),
            6
        )
    }

    func testBoundaryProgressHasStableResult() {
        XCTAssertNil(DoorFirmwareProgressEstimation.secondsRemaining(
            progress: 0,
            packageBytes: 100,
            averageBytesPerSecond: 10,
            elapsedUploadTime: 0
        ))
        XCTAssertEqual(DoorFirmwareProgressEstimation.secondsRemaining(
            progress: 100,
            packageBytes: 100,
            averageBytesPerSecond: 10,
            elapsedUploadTime: 10
        ), 0)
    }
}
