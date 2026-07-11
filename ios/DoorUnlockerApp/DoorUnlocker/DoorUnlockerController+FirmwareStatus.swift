import CoreBluetooth
import DoorUnlockerShared
import UIKit
import UserNotifications

private let doorUnlockerFirmwareUpdateNotificationIdentifier = "DoorUnlockerFirmwareUpdateFinished"

extension DoorUnlockerController {
    static func storedFirmwareVersion() -> String {
        guard let version = UserDefaults.standard.string(forKey: cachedFirmwareVersionKey) else {
            return "Unknown"
        }

        let trimmedVersion = version.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedVersion.isEmpty ? "Unknown" : trimmedVersion
    }

    var firmwareVersionDisplayText: String {
        firmwareVersion == "Unknown" ? "Firmware unknown" : "Firmware \(firmwareVersion)"
    }

    var isFirmwareUpdateVerifying: Bool {
        firmwareUpdateStatus == "Update complete. Verifying..." ||
            firmwareUpdateStatus == "Checking controller firmware..."
    }

    var isFirmwareUpdateFailureVisible: Bool {
        let normalizedStatus = firmwareUpdateStatus.lowercased()
        return normalizedStatus.contains("failed") ||
            normalizedStatus.contains("rejected") ||
            normalizedStatus.contains("could not") ||
            normalizedStatus.contains("aborted") ||
            normalizedStatus.contains("timed out")
    }

    var isFirmwareUpdateSuccessVisible: Bool {
        let normalizedStatus = firmwareUpdateStatus.lowercased()
        return normalizedStatus.hasPrefix("update finished") ||
            normalizedStatus.hasPrefix("verified")
    }

    var shouldSuppressFirmwareUpdateTransientErrors: Bool {
        isFirmwareUpdateRunning || isFirmwareUpdateVerifying || isFirmwareUpdateSuccessVisible
    }

    var shouldBlockDoorControlForFirmwareUpdate: Bool {
        shouldSuppressFirmwareUpdateTransientErrors
    }

    var firmwareUpdateControlTitle: String {
        if isFirmwareUpdateSuccessVisible {
            return "Firmware updated"
        }

        if isFirmwareUpdateVerifying {
            return "Verifying firmware..."
        }

        if isFirmwareUpdateRunning {
            return "Updating firmware..."
        }

        return "Firmware update"
    }

    var firmwareUpdateETAText: String? {
        guard isFirmwareUpdateRunning,
              let seconds = firmwareUpdateEstimatedSecondsRemaining,
              seconds > 0 else {
            return nil
        }

        return "About \(Self.formattedFirmwareETA(seconds)) remaining"
    }

    private static func formattedFirmwareETA(_ seconds: Int) -> String {
        let clampedSeconds = max(1, seconds)
        if clampedSeconds < 60 {
            return "\(clampedSeconds)s"
        }

        let minutes = clampedSeconds / 60
        let remainingSeconds = clampedSeconds % 60
        if remainingSeconds == 0 {
            return "\(minutes)m"
        }

        return "\(minutes)m \(remainingSeconds)s"
    }

    func isCurrentPeripheral(_ peripheral: CBPeripheral) -> Bool {
        self.peripheral?.identifier == peripheral.identifier
    }

    @discardableResult
    func readStateIfPermitted() -> Bool {
        guard let peripheral, let stateCharacteristic else {
            return false
        }

        guard stateCharacteristic.properties.contains(.read) else {
            return false
        }

        peripheral.readValue(for: stateCharacteristic)
        return true
    }

    func scheduleFirmwareVersionSnapshotRetry(delay: Duration = .milliseconds(420)) {
        guard !hasCompleteControllerMetadataSnapshot else {
            firmwareVersionSnapshotRetryTask?.cancel()
            firmwareVersionSnapshotRetryTask = nil
            return
        }
        firmwareVersionSnapshotRetryTask?.cancel()
        firmwareVersionSnapshotRetryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            await MainActor.run {
                guard let self else { return }
                self.firmwareVersionSnapshotRetryTask = nil
                guard !self.hasCompleteControllerMetadataSnapshot else { return }
                switch DoorFirmwareSnapshotPolicy.action(
                    isControllerReady: self.isReady,
                    hasQueuedDoorCommand: self.pendingFreshNonceDoorCommand != nil,
                    hasInFlightDoorCommand: self.optimisticDoorCommand != nil,
                    hasControllerSettingOperation: self.isApplyingControllerSetting
                ) {
                case .stop:
                    return
                case .deferUntilCommandCompletes:
                    self.scheduleFirmwareVersionSnapshotRetry(delay: .milliseconds(250))
                case .request:
                    self.requestStateNotificationSnapshotReplay()
                }
            }
        }
    }

    func requestStateNotificationSnapshotReplay() {
        guard !hasCompleteControllerMetadataSnapshot else { return }
        guard isDoorCommandReady,
              !controllerNonceHandoffGate.isInFlight,
              !linkAuthenticationInFlight,
              pendingCommandWriteIntents.isEmpty else {
            scheduleStateSnapshotFallbackRead(delay: .milliseconds(350))
            scheduleFirmwareVersionSnapshotRetry(delay: .milliseconds(350))
            return
        }

        guard let peripheral, let commandCharacteristic else {
            _ = readStateIfPermitted()
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        guard let generation = stateSnapshotRequestGate.begin(at: now, minimumInterval: 0.8) else {
            scheduleFirmwareVersionSnapshotRetry(delay: .milliseconds(350))
            return
        }
        stateSnapshotRequestTimeoutTask?.cancel()
        stateSnapshotRequestTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(750))
            await MainActor.run {
                guard let self,
                      self.stateSnapshotRequestGate.expire(generation: generation) else { return }
                self.stateSnapshotRequestTimeoutTask = nil
            }
        }

        let payload = Data("snapshot".utf8)
        if commandCharacteristic.properties.contains(.write) {
            peripheral.writeValue(payload, for: commandCharacteristic, type: .withResponse)
        } else if commandCharacteristic.properties.contains(.writeWithoutResponse),
                  peripheral.canSendWriteWithoutResponse {
            peripheral.writeValue(payload, for: commandCharacteristic, type: .withoutResponse)
        } else {
            _ = readStateIfPermitted()
            return
        }
#if DEBUG
        recordStartupTelemetry("controller_snapshot_requested", once: false)
#endif
        // Continue until session, health, state, roster, and firmware are current.
        scheduleFirmwareVersionSnapshotRetry(delay: .seconds(1.2))
    }

    var hasCompleteControllerMetadataSnapshot: Bool {
        controllerFreshness.hasCompleteMetadataSnapshot(
            hasCurrentFirmwareVersion: hasCurrentFirmwareVersionSnapshot
        )
    }

    func refreshControllerMetadataSnapshotRetry() {
        if hasCompleteControllerMetadataSnapshot {
            firmwareVersionSnapshotRetryTask?.cancel()
            firmwareVersionSnapshotRetryTask = nil
        } else if isReady {
            scheduleFirmwareVersionSnapshotRetry(delay: .milliseconds(350))
        }
    }

    var shouldShowFirmwareUpdateBanner: Bool {
        isFirmwareUpdateRunning ||
            isFirmwareUpdateVerifying ||
            isFirmwareUpdateSuccessVisible ||
            isFirmwareUpdateFailureVisible
    }

    func scheduleFirmwareUpdateSuccessReset() {
        firmwareUpdateCompletionResetTask?.cancel()
        firmwareUpdateCompletionResetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.firmwareUpdateSuccessDisplayDuration))
            await MainActor.run {
                guard let self, self.isFirmwareUpdateSuccessVisible else { return }
                self.clearSuccessfulFirmwareUpdatePresentationIfNeeded()
                self.firmwareUpdateCompletionResetTask = nil
            }
        }
    }

    func cancelFirmwareUpdateSuccessReset() {
        firmwareUpdateCompletionResetTask?.cancel()
        firmwareUpdateCompletionResetTask = nil
    }

    func clearSuccessfulFirmwareUpdatePresentationIfNeeded() {
        guard isFirmwareUpdateSuccessVisible else { return }
        firmwareUpdateStatus = "Ready"
        firmwareUpdateProgress = nil
        firmwareUpdateEstimatedSecondsRemaining = nil
    }

    func syncFirmwareUpdateLiveActivityIfNeeded() {
        guard firmwareUpdateStatus != "Ready" else { return }

        let normalizedStatus = firmwareUpdateStatus.lowercased()
        if normalizedStatus.contains("failed") ||
            normalizedStatus.contains("rejected") ||
            normalizedStatus.contains("could not") ||
            normalizedStatus.contains("aborted") {
            firmwareLiveActivityCoordinator.fail(lockName: lockName, message: firmwareUpdateStatus)
            return
        }

        firmwareLiveActivityCoordinator.update(
            lockName: lockName,
            status: firmwareUpdateStatus,
            progress: firmwareUpdateProgress,
            estimatedSecondsRemaining: firmwareUpdateEstimatedSecondsRemaining
        )
    }

    func finishFirmwareUpdateLiveActivity(version: String) {
        firmwareLiveActivityCoordinator.finish(lockName: lockName, version: version)
    }

    func requestFirmwareUpdateNotificationAuthorizationIfNeeded() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }

            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] _, _ in
                Task { @MainActor in
                    self?.refreshNotificationSettings()
                }
            }
        }
    }

    func notifyFirmwareUpdateFinished(version: String) {
        guard UIApplication.shared.applicationState != .active else { return }

        let notificationLockName = lockName
        let notificationIdentifier = doorUnlockerFirmwareUpdateNotificationIdentifier

        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized ||
                    settings.authorizationStatus == .provisional ||
                    settings.authorizationStatus == .ephemeral else {
                return
            }

            let content = UNMutableNotificationContent()
            content.title = "\(notificationLockName) firmware updated"
            content.body = "Controller is now on \(version)."
            content.sound = .default
            content.threadIdentifier = "DoorUnlocker"

            let request = UNNotificationRequest(
                identifier: notificationIdentifier,
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [notificationIdentifier])
            UNUserNotificationCenter.current().add(request)
        }
    }
}
