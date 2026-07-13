import XCTest
@testable import DoorUnlockerShared

final class DoorFirmwareRetryPolicyTests: XCTestCase {
    func testRejectsIntegrityFailureAndCapsTransientAttempts() {
        let retryable = journal(attemptCount: 2)
        XCTAssertTrue(
            DoorFirmwareRetryPolicy.shouldAutomaticallyRetry(
                journal: retryable,
                errorMessage: "Bluetooth disconnected"
            )
        )
        XCTAssertFalse(
            DoorFirmwareRetryPolicy.shouldAutomaticallyRetry(
                journal: retryable,
                errorMessage: "CRC Error"
            )
        )
        XCTAssertFalse(
            DoorFirmwareRetryPolicy.shouldAutomaticallyRetry(
                journal: journal(attemptCount: 3),
                errorMessage: "Bluetooth disconnected"
            )
        )
    }

    func testNordicIntegrityAndCompatibilityErrorsAreTerminal() {
        let terminalMessages = [
            "CRC Error",
            "Signature missing",
            "Signature mismatch",
            "Invalid hash type",
            "Hashing failed",
            "Operation failed. Ensure the firmware targets that device type and version.",
            "Invalid object",
            "Unsupported type",
            "Package changed after staging"
        ]

        for message in terminalMessages {
            XCTAssertEqual(
                DoorFirmwareRetryPolicy.disposition(for: message),
                .terminal,
                message
            )
        }
    }

    func testTransportAndVerificationInterruptionsRemainRetryable() {
        let transientMessages = [
            "Bluetooth transport disconnected during firmware update.",
            "Controller did not advertise firmware update mode.",
            "Post-update firmware verification timed out.",
            "Controller reboot was not observed yet."
        ]

        for message in transientMessages {
            XCTAssertEqual(
                DoorFirmwareRetryPolicy.disposition(for: message),
                .retryable,
                message
            )
        }
    }

    func testAttemptCountTracksUploadsRatherThanPreparationPhases() {
        var journal = journal(attemptCount: 0)

        journal.transition(to: .requestingBootloader)
        XCTAssertEqual(journal.attemptCount, 0)
        journal.transition(to: .scanningForBootloader)
        journal.transition(to: .uploading)
        XCTAssertEqual(journal.attemptCount, 1)
        journal.transition(to: .paused)
        journal.transition(to: .uploading)
        XCTAssertEqual(journal.attemptCount, 2)
    }

    private func journal(attemptCount: Int) -> DoorFirmwareUpdateJournal {
        DoorFirmwareUpdateJournal(
            targetVersion: "0.2.0",
            packagePath: "/firmware.zip",
            packageByteCount: 130_000,
            attemptCount: attemptCount
        )
    }
}
