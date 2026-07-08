import CoreBluetooth
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
        firmwareUpdateStatus == "Update complete. Verifying..."
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
        firmwareVersionSnapshotRetryTask?.cancel()
        let generation = stateUpdateGeneration
        firmwareVersionSnapshotRetryTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            await MainActor.run {
                guard let self,
                      self.isReady,
                      self.stateUpdateGeneration == generation || self.firmwareVersion == "Unknown" || self.firmwareUpdateStatus == "Update complete. Verifying..." else {
                    return
                }

                self.firmwareVersionSnapshotRetryTask = nil
                guard self.firmwareVersion == "Unknown" || self.firmwareUpdateStatus == "Update complete. Verifying..." else {
                    return
                }

                self.requestStateNotificationSnapshotReplay()
            }
        }
    }

    func requestStateNotificationSnapshotReplay() {
        guard let peripheral,
              let stateCharacteristic,
              stateCharacteristic.properties.contains(.notify) || stateCharacteristic.properties.contains(.indicate) else {
            _ = readStateIfPermitted()
            return
        }

        if stateCharacteristic.isNotifying {
            peripheral.setNotifyValue(false, for: stateCharacteristic)
            Task { [weak self, weak peripheral, weak stateCharacteristic] in
                try? await Task.sleep(for: .milliseconds(90))
                await MainActor.run {
                    guard let self,
                          let peripheral,
                          let stateCharacteristic,
                          self.isCurrentPeripheral(peripheral),
                          self.stateCharacteristic?.uuid == stateCharacteristic.uuid,
                          peripheral.state == .connected else {
                        return
                    }

                    peripheral.setNotifyValue(true, for: stateCharacteristic)
                }
            }
        } else {
            peripheral.setNotifyValue(true, for: stateCharacteristic)
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
            progress: firmwareUpdateProgress
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
