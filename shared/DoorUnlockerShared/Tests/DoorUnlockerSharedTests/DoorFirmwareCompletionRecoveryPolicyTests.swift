import XCTest
@testable import DoorUnlockerShared

final class DoorFirmwareCompletionRecoveryPolicyTests: XCTestCase {
    func testDoesNotDeclareUploadCompleteBeforeTransportReportsOneHundredPercent() {
        XCTAssertFalse(
            DoorFirmwareCompletionRecoveryPolicy.shouldProbeNormalFirmware(
                didReportFinalPartComplete: false
            )
        )
    }

    func testAllowsNormalModeProbeAfterTransportReportsOneHundredPercent() {
        XCTAssertTrue(
            DoorFirmwareCompletionRecoveryPolicy.shouldProbeNormalFirmware(
                didReportFinalPartComplete: true
            )
        )
    }

    func testIntermediatePartAtOneHundredPercentDoesNotCompleteMultipartUpload() {
        XCTAssertFalse(
            DoorFirmwareCompletionRecoveryPolicy.isFinalPartComplete(
                part: 1,
                totalParts: 2,
                progress: 100
            )
        )
    }

    func testFinalPartAtOneHundredPercentCompletesMultipartUpload() {
        XCTAssertTrue(
            DoorFirmwareCompletionRecoveryPolicy.isFinalPartComplete(
                part: 2,
                totalParts: 2,
                progress: 100
            )
        )
    }

    func testFinalPartAtNinetyNinePercentDoesNotCompleteUpload() {
        XCTAssertFalse(
            DoorFirmwareCompletionRecoveryPolicy.isFinalPartComplete(
                part: 2,
                totalParts: 2,
                progress: 99
            )
        )
    }
}
