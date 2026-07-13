import DoorUnlockerShared
import Foundation

extension DoorUnlockerController {
    private var firmwareUpdateJournalStore: DoorFirmwareUpdateJournalStore {
        DoorFirmwareUpdateJournalStore(key: Self.firmwareUpdateJournalKey)
    }

    var bundledFirmwarePackageURL: URL? {
        Bundle.main.url(forResource: "DoorUnlockerXiao-dfu", withExtension: "zip")
    }

    var bundledSignedFirmwarePackageURL: URL? {
        Bundle.main.url(forResource: "DoorUnlockerXiao-signed-dfu", withExtension: "zip")
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
            UserDefaults.standard.removeObject(forKey: Self.failedFirmwareActivationVersionKey)
            persistPendingBundledFirmwareUpdate(targetVersion: targetVersion, resetAttempts: true)
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
              UserDefaults.standard.string(forKey: Self.failedFirmwareActivationVersionKey) != targetVersion,
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

    func persistPendingBundledFirmwareUpdate(
        targetVersion: String,
        resetAttempts: Bool = false
    ) {
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
        if resetAttempts
            || journal.targetVersion != targetVersion
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
        firmwareDfuStartFallbackTask?.cancel()
        firmwareDfuStartFallbackTask = nil
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Self.pendingBundledFirmwareUpdateVersionKey)
        defaults.removeObject(forKey: Self.pendingBundledFirmwareUpdateStartedAtKey)
        firmwareUpdateJournalStore.clear()
    }

    func scheduleInterruptedFirmwareUpdateRetry(after delay: Duration = .seconds(3)) {
        guard let journal = firmwareUpdateJournalStore.load(),
              journal.attemptCount < DoorFirmwareRetryPolicy.maximumAutomaticUploadAttempts else {
            return
        }
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
        UserDefaults.standard.removeObject(forKey: Self.failedFirmwareActivationVersionKey)
    }

    @discardableResult
    func stopFirmwareUpdateAfterActivationMismatchIfNeeded(installedVersion: String) -> Bool {
        guard let journal = firmwareUpdateJournalStore.load(),
              DoorFirmwareRecoveryPolicy.action(
                journal: journal,
                installedVersion: installedVersion,
                isNormalControllerReady: true,
                isBootloaderDetected: false,
                isPackageAvailable: bundledFirmwarePackageURL != nil
              ) == .activationFailed,
              let targetVersion = journal.targetVersion else {
            return false
        }

        UserDefaults.standard.set(targetVersion, forKey: Self.failedFirmwareActivationVersionKey)
        clearPendingBundledFirmwareUpdate()
        autoBundledFirmwareUpdateAttemptedVersion = targetVersion
        pendingFirmwareUpdatePackageURL = nil
        firmwareUpdateEntryCommandSent = false
        isFirmwareUpdateRunning = false
        firmwareUpdateProgress = nil
        firmwareUpdateEstimatedSecondsRemaining = nil
        firmwareUpdateStatus = "Firmware activation failed"
        lastError = "The upload completed, but the controller restarted on firmware \(installedVersion). The update was stopped instead of retrying automatically."
#if DEBUG
        recordStartupTelemetry(
            "firmware_activation_failed",
            details: "expected=\(targetVersion) actual=\(installedVersion)",
            once: false
        )
#endif
        return true
    }

    func resumeInterruptedBundledFirmwareUpdateIfNeeded() {
        guard !isFirmwareUpdateRunning,
              let packageURL = bundledFirmwarePackageURL else {
            return
        }

        if let journal = firmwareUpdateJournalStore.load(),
           journal.attemptCount >= DoorFirmwareRetryPolicy.maximumAutomaticUploadAttempts {
            firmwareUpdateStatus = "Firmware update paused after repeated failures"
            return
        }

        let defaults = UserDefaults.standard
        let pendingVersion = firmwareUpdateJournalStore.load()?.targetVersion
            ?? defaults.string(forKey: Self.pendingBundledFirmwareUpdateVersionKey)
        let hasExplicitPendingUpdate = pendingVersion?.isEmpty == false
        guard hasExplicitPendingUpdate,
              let targetVersion = pendingVersion else { return }

        probeNormalFirmwareBeforeInterruptedDfuResume(
            targetVersion: targetVersion,
            packageURL: packageURL
        )
    }

    func canAutomaticallyRetryPendingFirmwareUpdate(after message: String) -> Bool {
        DoorFirmwareRetryPolicy.shouldAutomaticallyRetry(
            journal: firmwareUpdateJournalStore.load(),
            errorMessage: message
        )
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

    private func probeNormalFirmwareBeforeInterruptedDfuResume(
        targetVersion: String,
        packageURL: URL
    ) {
        persistPendingBundledFirmwareUpdate(targetVersion: targetVersion)
        autoBundledFirmwareUpdateAttemptedVersion = nil
        firmwareUpdateStatus = "Checking interrupted firmware update"
#if DEBUG
        recordStartupTelemetry("firmware_recovery_normal_probe", details: targetVersion, once: false)
#endif
        requestControllerConnectionIfNeeded()
        firmwareDfuStartFallbackTask?.cancel()
        firmwareDfuStartFallbackTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            await MainActor.run {
                guard let self,
                      !self.isFirmwareUpdateRunning,
                      !self.isReady,
                      self.firmwareUpdateJournalStore.load() != nil else {
                    return
                }
                self.firmwareDfuStartFallbackTask = nil
                self.startInterruptedBundledFirmwareDfuResume(
                    targetVersion: targetVersion,
                    packageURL: packageURL
                )
            }
        }
    }
}
