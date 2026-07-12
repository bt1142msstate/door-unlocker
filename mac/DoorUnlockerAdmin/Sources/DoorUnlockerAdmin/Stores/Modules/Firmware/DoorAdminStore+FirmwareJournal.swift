import DoorUnlockerCore
import DoorUnlockerShared
import Foundation

extension DoorAdminStore {
    private static let firmwareUpdateJournalKey = "DoorUnlockerAdminFirmwareUpdateJournalV1"

    private var firmwareUpdateJournalStore: DoorFirmwareUpdateJournalStore {
        DoorFirmwareUpdateJournalStore(key: Self.firmwareUpdateJournalKey)
    }

    func persistFirmwareUpdateJournal(packageURL: URL, targetVersion: String?) {
        let packageBytes = (try? packageURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let packageSHA256 = try? DoorFirmwarePackageFingerprint.sha256(of: packageURL)
        let journal = DoorFirmwareUpdateJournal(
            targetVersion: targetVersion,
            packagePath: packageURL.path,
            packageByteCount: packageBytes,
            packageSHA256: packageSHA256
        )
        firmwareUpdateJournalStore.save(journal)
    }

    func updateFirmwareUpdateJournal(
        phase: DoorFirmwareUpdatePhase,
        progress: Int? = nil,
        error: String? = nil
    ) {
        guard var journal = firmwareUpdateJournalStore.load() else { return }
        journal.transition(to: phase, progress: progress, error: error)
        firmwareUpdateJournalStore.save(journal)
    }

    func clearFirmwareUpdateJournal() {
        firmwareUpdateRecoveryRetryTask?.cancel()
        firmwareUpdateRecoveryRetryTask = nil
        firmwareUpdateJournalStore.clear()
    }

    func scheduleInterruptedFirmwareUpdateRetry(after delay: Duration = .seconds(3)) {
        guard firmwareUpdateJournalStore.load() != nil else { return }
        firmwareUpdateRecoveryRetryTask?.cancel()
        firmwareUpdateRecoveryRetryTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            await MainActor.run {
                guard let self, !self.isFirmwareUpdateRunning else { return }
                self.firmwareUpdateRecoveryRetryTask = nil
                self.resumeInterruptedFirmwareUpdateIfNeeded()
            }
        }
    }

    func resumeInterruptedFirmwareUpdateIfNeeded() {
        guard !isFirmwareUpdateRunning,
              let journal = firmwareUpdateJournalStore.load() else { return }
        let packageURL = URL(fileURLWithPath: journal.packagePath)
        guard DoorFirmwarePackageFingerprint.matches(journal, packageURL: packageURL) else {
            firmwareUpdateStatus = "Firmware package needs replacement"
            lastError = "The saved firmware package is missing or changed. Start the update again."
            return
        }

        expectedFirmwareVerificationVersion = journal.targetVersion
        firmwareUpdateStatus = "Resuming firmware update"
        firmwareUpdateProgress = journal.lastProgress
        isFirmwareUpdateRunning = true
        lastError = nil
        updateFirmwareUpdateJournal(phase: .scanningForBootloader)
        beginFirmwareDfuUpload(after: packageURL, detectsNormalControllerFirmware: true)
    }

    func reconcileFirmwareUpdateJournal(installedVersion: String) {
        guard let journal = firmwareUpdateJournalStore.load() else { return }
        let packageURL = URL(fileURLWithPath: journal.packagePath)
        switch DoorFirmwareRecoveryPolicy.action(
            journal: journal,
            installedVersion: installedVersion,
            isNormalControllerReady: true,
            isBootloaderDetected: false,
            isPackageAvailable: DoorFirmwarePackageFingerprint.matches(journal, packageURL: packageURL)
        ) {
        case .completed:
            clearFirmwareUpdateJournal()
        case .restartFromNormalFirmware:
            guard !isFirmwareUpdateRunning else { return }
            expectedFirmwareVerificationVersion = journal.targetVersion
            startFirmwareUpdate(packageURL: packageURL)
        case .verifyNormalFirmware where journal.targetVersion == nil && journal.phase == .verifying:
            clearFirmwareUpdateJournal()
        case .needsPackage:
            firmwareUpdateStatus = "Firmware update needs its package"
        case .none, .waitForController, .resumeBootloaderUpload, .verifyNormalFirmware:
            break
        }
    }
}
