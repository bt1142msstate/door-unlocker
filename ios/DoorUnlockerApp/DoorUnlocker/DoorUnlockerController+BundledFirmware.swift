import DoorUnlockerShared
import Foundation

extension DoorUnlockerController {
    private var firmwareUpdateJournalStore: DoorFirmwareUpdateJournalStore {
        DoorFirmwareUpdateJournalStore(key: Self.firmwareUpdateJournalKey)
    }

    var bundledFirmwarePackageURL: URL? {
        Bundle.main.url(forResource: "DoorUnlockerXiao-dfu", withExtension: "zip")
    }

    var bundledFirmwareVersion: String? {
        Self.bundledFirmwareVersion()
    }

    var bundledFirmwareVersionDisplayText: String {
        bundledFirmwareVersion.map { "Bundled firmware \($0)" } ?? "Bundled firmware unknown"
    }

    func startBundledFirmwareUpdate() {
        guard let url = bundledFirmwarePackageURL else {
#if DEBUG
            recordStartupTelemetry("firmware_bundle_missing", once: false)
#endif
            lastError = "No bundled firmware update package was found."
            return
        }

        if let targetVersion = bundledFirmwareVersion {
            persistPendingBundledFirmwareUpdate(targetVersion: targetVersion)
        }
#if DEBUG
        recordStartupTelemetry("firmware_bundle_found", details: url.lastPathComponent, once: false)
#endif
        startFirmwareUpdate(packageURL: url)
    }

    private static func bundledFirmwareVersion() -> String? {
        let explicitVersion = Bundle.main.object(forInfoDictionaryKey: "DoorControllerFirmwareVersion") as? String
        let fallbackVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let version = explicitVersion ?? fallbackVersion
        let trimmedVersion = version?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedVersion?.isEmpty == false ? trimmedVersion : nil
    }

    private func startAutomaticBundledFirmwareUpdate(targetVersion: String) {
        guard let url = bundledFirmwarePackageURL else {
#if DEBUG
            recordStartupTelemetry("auto_firmware_bundle_missing", once: false)
#endif
            return
        }

        persistPendingBundledFirmwareUpdate(targetVersion: targetVersion)
        autoBundledFirmwareUpdateAttemptedVersion = targetVersion
        autoBundledFirmwareUpdateEvaluatedVersionPair = nil
#if DEBUG
        recordStartupTelemetry("auto_firmware_update_start", details: targetVersion, once: false)
#endif
        startFirmwareUpdate(packageURL: url, requiresSettingsUnlock: false)
    }

    func evaluateBundledFirmwareAutoUpdate(installedVersion: String) {
        guard !isFirmwareUpdateRunning,
              !isFirmwareUpdateVerifying,
              pendingFirmwareUpdatePackageURL == nil,
              let targetVersion = bundledFirmwareVersion,
              autoBundledFirmwareUpdateAttemptedVersion != targetVersion else {
            return
        }

        let evaluatedPair = "\(installedVersion)->\(targetVersion)"
        guard autoBundledFirmwareUpdateEvaluatedVersionPair != evaluatedPair else {
            return
        }
        autoBundledFirmwareUpdateEvaluatedVersionPair = evaluatedPair

        let decision = DoorFirmwareUpdatePolicy.decision(
            installedVersion: installedVersion,
            bundledVersion: targetVersion
        )

        guard decision == .installBundledVersion else {
#if DEBUG
            recordStartupTelemetry("auto_firmware_no_update", details: evaluatedPair, once: false)
#endif
            return
        }

        firmwareUpdateStatus = "Firmware \(targetVersion) is included with this app. Updating controller..."
        startAutomaticBundledFirmwareUpdate(targetVersion: targetVersion)
    }

    func persistPendingBundledFirmwareUpdate(targetVersion: String) {
        let defaults = UserDefaults.standard
        defaults.set(targetVersion, forKey: Self.pendingBundledFirmwareUpdateVersionKey)
        defaults.set(Date().timeIntervalSince1970, forKey: Self.pendingBundledFirmwareUpdateStartedAtKey)
        guard let packageURL = bundledFirmwarePackageURL else { return }
        let packageBytes = (try? packageURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let packageSHA256 = try? DoorFirmwarePackageFingerprint.sha256(of: packageURL)
        var journal = firmwareUpdateJournalStore.load() ?? DoorFirmwareUpdateJournal(
            targetVersion: targetVersion,
            packagePath: packageURL.path,
            packageByteCount: packageBytes,
            packageSHA256: packageSHA256
        )
        if journal.targetVersion != targetVersion
            || journal.packagePath != packageURL.path
            || !DoorFirmwarePackageFingerprint.matches(journal, packageURL: packageURL) {
            journal = DoorFirmwareUpdateJournal(
                targetVersion: targetVersion,
                packagePath: packageURL.path,
                packageByteCount: packageBytes,
                packageSHA256: packageSHA256
            )
        }
        firmwareUpdateJournalStore.save(journal)
    }

    func updatePendingFirmwareJournal(
        phase: DoorFirmwareUpdatePhase,
        progress: Int? = nil,
        error: String? = nil
    ) {
        guard var journal = firmwareUpdateJournalStore.load() else { return }
        journal.transition(to: phase, progress: progress, error: error)
        firmwareUpdateJournalStore.save(journal)
    }

    func clearPendingBundledFirmwareUpdate() {
        firmwareUpdateRecoveryRetryTask?.cancel()
        firmwareUpdateRecoveryRetryTask = nil
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Self.pendingBundledFirmwareUpdateVersionKey)
        defaults.removeObject(forKey: Self.pendingBundledFirmwareUpdateStartedAtKey)
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
                self.resumeInterruptedBundledFirmwareUpdateIfNeeded()
            }
        }
    }

    func clearPendingBundledFirmwareUpdateIfVerified(installedVersion: String) {
        guard let pendingVersion = firmwareUpdateJournalStore.load()?.targetVersion
            ?? UserDefaults.standard.string(forKey: Self.pendingBundledFirmwareUpdateVersionKey) else {
            return
        }

        let decision = DoorFirmwareUpdatePolicy.decision(
            installedVersion: installedVersion,
            bundledVersion: pendingVersion
        )
        guard decision != .installBundledVersion else { return }

#if DEBUG
        recordStartupTelemetry("firmware_pending_cleared", details: "\(installedVersion)->\(pendingVersion)", once: false)
#endif
        clearPendingBundledFirmwareUpdate()
    }

    func resumeInterruptedBundledFirmwareUpdateIfNeeded() {
        guard !isFirmwareUpdateRunning,
              let packageURL = bundledFirmwarePackageURL else {
            return
        }

        let defaults = UserDefaults.standard
        let pendingVersion = firmwareUpdateJournalStore.load()?.targetVersion
            ?? defaults.string(forKey: Self.pendingBundledFirmwareUpdateVersionKey)
        let hasExplicitPendingUpdate = pendingVersion?.isEmpty == false
        guard hasExplicitPendingUpdate,
              let targetVersion = pendingVersion else { return }

        startInterruptedBundledFirmwareDfuResume(targetVersion: targetVersion, packageURL: packageURL)
    }

    @discardableResult
    func resumeBundledFirmwareFromDetectedBootloaderIfNeeded() -> Bool {
        guard !isFirmwareUpdateRunning,
              let packageURL = bundledFirmwarePackageURL,
              let targetVersion = bundledFirmwareVersion else {
            return false
        }

        let pendingVersion = firmwareUpdateJournalStore.load()?.targetVersion
            ?? UserDefaults.standard.string(forKey: Self.pendingBundledFirmwareUpdateVersionKey)
        let hasPendingUpdate = pendingVersion?.isEmpty == false
        let bundledFirmwareIsNewer = DoorFirmwareUpdatePolicy.shouldInstallBundledFirmware(
            installedVersion: firmwareVersion,
            bundledVersion: targetVersion
        )
        guard hasPendingUpdate || bundledFirmwareIsNewer else {
            return false
        }

        persistPendingBundledFirmwareUpdate(targetVersion: targetVersion)
#if DEBUG
        recordStartupTelemetry("firmware_bootloader_handoff", details: targetVersion, once: false)
#endif
        startInterruptedBundledFirmwareDfuResume(targetVersion: targetVersion, packageURL: packageURL)
        return true
    }

    private func startInterruptedBundledFirmwareDfuResume(targetVersion: String, packageURL: URL) {
        persistPendingBundledFirmwareUpdate(targetVersion: targetVersion)
        autoBundledFirmwareUpdateAttemptedVersion = targetVersion
        updatePendingFirmwareJournal(phase: .scanningForBootloader)
#if DEBUG
        recordStartupTelemetry("firmware_resume_dfu", details: targetVersion, once: false)
#endif
        resumeFirmwareDfuUpload(packageURL: packageURL, status: "Resuming firmware update")
    }
}
