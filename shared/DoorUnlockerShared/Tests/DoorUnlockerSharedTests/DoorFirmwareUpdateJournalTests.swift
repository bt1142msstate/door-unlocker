import XCTest
@testable import DoorUnlockerShared

final class DoorFirmwareUpdateJournalTests: XCTestCase {
    func testJournalRoundTripsAndClampsProgress() {
        let suite = "DoorFirmwareUpdateJournalTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = DoorFirmwareUpdateJournalStore(defaults: defaults, key: "journal")
        var journal = DoorFirmwareUpdateJournal(
            targetVersion: "0.2.0",
            packagePath: "/firmware.zip",
            packageByteCount: 130_000
        )

        journal.transition(to: .uploading, progress: 140)
        store.save(journal)

        XCTAssertEqual(store.load(), journal)
        XCTAssertEqual(store.load()?.lastProgress, 100)
        XCTAssertEqual(store.load()?.attemptCount, 1)
        store.clear()
        XCTAssertNil(store.load())
    }

    func testPowerLossInBootloaderResumesWhenPackageExists() {
        let journal = DoorFirmwareUpdateJournal(
            targetVersion: "0.2.0",
            packagePath: "/firmware.zip",
            packageByteCount: 130_000,
            phase: .paused,
            lastProgress: 47,
            lastError: "Bluetooth disconnected"
        )

        XCTAssertEqual(
            DoorFirmwareRecoveryPolicy.action(
                journal: journal,
                installedVersion: nil,
                isNormalControllerReady: false,
                isBootloaderDetected: true,
                isPackageAvailable: true
            ),
            .resumeBootloaderUpload
        )
    }

    func testOldNormalFirmwareRestartsAfterInterruptedUpload() {
        let journal = DoorFirmwareUpdateJournal(
            targetVersion: "0.2.0",
            packagePath: "/firmware.zip",
            packageByteCount: 130_000,
            phase: .paused
        )

        XCTAssertEqual(
            DoorFirmwareRecoveryPolicy.action(
                journal: journal,
                installedVersion: "0.1.9",
                isNormalControllerReady: true,
                isBootloaderDetected: false,
                isPackageAvailable: true
            ),
            .restartFromNormalFirmware
        )
    }

    func testInstalledTargetCompletesWithoutAnotherUpload() {
        let journal = DoorFirmwareUpdateJournal(
            targetVersion: "0.2.0",
            packagePath: "/firmware.zip",
            packageByteCount: 130_000,
            phase: .verifying
        )

        XCTAssertEqual(
            DoorFirmwareRecoveryPolicy.action(
                journal: journal,
                installedVersion: "0.2.0",
                isNormalControllerReady: true,
                isBootloaderDetected: false,
                isPackageAvailable: true
            ),
            .completed
        )
    }

    func testMissingPackageNeverAttemptsUpdate() {
        let journal = DoorFirmwareUpdateJournal(
            targetVersion: "0.2.0",
            packagePath: "/missing.zip",
            packageByteCount: 130_000,
            phase: .paused
        )

        XCTAssertEqual(
            DoorFirmwareRecoveryPolicy.action(
                journal: journal,
                installedVersion: "0.1.9",
                isNormalControllerReady: true,
                isBootloaderDetected: false,
                isPackageAvailable: false
            ),
            .needsPackage
        )
    }

    func testManualUpdateCompletesWhenNormalFirmwareReturnsAfterUpload() {
        let journal = DoorFirmwareUpdateJournal(
            targetVersion: nil,
            packagePath: "/firmware.zip",
            packageByteCount: 130_000,
            phase: .verifying
        )

        XCTAssertEqual(
            DoorFirmwareRecoveryPolicy.action(
                journal: journal,
                installedVersion: "0.2.0",
                isNormalControllerReady: true,
                isBootloaderDetected: false,
                isPackageAvailable: true
            ),
            .completed
        )
    }

    func testPackageFingerprintRejectsMutation() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DoorFirmwareUpdateJournalTests-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("firmware-a".utf8).write(to: url)
        let hash = try DoorFirmwarePackageFingerprint.sha256(of: url)
        let journal = DoorFirmwareUpdateJournal(
            targetVersion: "0.2.0",
            packagePath: url.path,
            packageByteCount: 10,
            packageSHA256: hash
        )

        XCTAssertTrue(DoorFirmwarePackageFingerprint.matches(journal, packageURL: url))
        try Data("firmware-b".utf8).write(to: url)
        XCTAssertFalse(DoorFirmwarePackageFingerprint.matches(journal, packageURL: url))
    }

    func testRecoveryDecisionPriorityAcrossEveryAdverseStateCombination() {
        let installedVersions: [String?] = [nil, "Unknown", "0.1.9", "0.2.0"]
        for phase in DoorFirmwareUpdatePhase.allCases {
            for installedVersion in installedVersions {
                for normalReady in [false, true] {
                    for bootloaderDetected in [false, true] {
                        for packageAvailable in [false, true] {
                            let journal = DoorFirmwareUpdateJournal(
                                targetVersion: "0.2.0",
                                packagePath: "/firmware.zip",
                                packageByteCount: 130_000,
                                phase: phase
                            )
                            let action = DoorFirmwareRecoveryPolicy.action(
                                journal: journal,
                                installedVersion: installedVersion,
                                isNormalControllerReady: normalReady,
                                isBootloaderDetected: bootloaderDetected,
                                isPackageAvailable: packageAvailable
                            )
                            XCTAssertEqual(
                                action,
                                expectedRecoveryAction(
                                    installedVersion: installedVersion,
                                    normalReady: normalReady,
                                    bootloaderDetected: bootloaderDetected,
                                    packageAvailable: packageAvailable
                                )
                            )
                        }
                    }
                }
            }
        }
    }

    func testCorruptJournalFailsClosed() {
        let suite = "DoorFirmwareUpdateJournalTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("partial-write".utf8), forKey: "journal")

        let store = DoorFirmwareUpdateJournalStore(defaults: defaults, key: "journal")
        XCTAssertNil(store.load())
    }

    private func expectedRecoveryAction(
        installedVersion: String?,
        normalReady: Bool,
        bootloaderDetected: Bool,
        packageAvailable: Bool
    ) -> DoorFirmwareRecoveryAction {
        if installedVersion == "0.2.0" { return .completed }
        if !packageAvailable { return .needsPackage }
        if bootloaderDetected { return .resumeBootloaderUpload }
        if !normalReady { return .waitForController }
        if installedVersion == nil || installedVersion == "Unknown" {
            return .verifyNormalFirmware
        }
        return .restartFromNormalFirmware
    }
}
