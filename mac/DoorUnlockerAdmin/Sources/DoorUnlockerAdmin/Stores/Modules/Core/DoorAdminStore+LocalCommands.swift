import CoreBluetooth
import DoorUnlockerCore
import DoorUnlockerDFU
import DoorUnlockerShared
import Foundation
import os

extension DoorAdminStore {
    func applyRemoteSettingApplying(kind: String, value: String?) {
        recordRuntimeTelemetry(
            "controller_setting_applying",
            details: value.map { "\(kind)=\($0)" } ?? kind,
            once: false
        )
        remoteSettingApplyTask?.cancel()
        remoteSettingApplyValue = value
        remoteSettingApplyKind = kind
        remoteSettingApplyTask = Task { [weak self] in
            guard await DoorControllerSettingDelay.wait(
                nanoseconds: DoorControllerSettingConfirmationPolicy.remoteSnapshotReplayDelayNanoseconds
            ) else { return }
            await MainActor.run {
                guard let self,
                      self.remoteSettingApplyKind == kind,
                      self.remoteSettingApplyValue == value else { return }
                self.requestWirelessStateNotificationSnapshotReplay()
            }
            let remainingVisibility = DoorControllerSettingConfirmationPolicy.remoteApplyVisibilityNanoseconds
                - DoorControllerSettingConfirmationPolicy.remoteSnapshotReplayDelayNanoseconds
            guard await DoorControllerSettingDelay.wait(nanoseconds: remainingVisibility) else { return }
            await MainActor.run {
                guard let self,
                      self.remoteSettingApplyKind == kind,
                      self.remoteSettingApplyValue == value else { return }
                self.clearRemoteSettingApplying()
            }
        }
    }

    func clearRemoteSettingApplying() {
        remoteSettingApplyTask?.cancel()
        remoteSettingApplyTask = nil
        remoteSettingApplyKind = nil
        remoteSettingApplyValue = nil
    }

    func postFirmwareVerificationIfNeeded(_ version: String) {
        guard isAwaitingPostDfuFirmwareVerification,
              !didPostFirmwareVerificationNotification,
              let expectedVersion = expectedFirmwareVerificationVersion else {
            return
        }

        guard version == expectedVersion else {
            firmwareLog.warning("Firmware verification mismatch expected=\(expectedVersion, privacy: .public) actual=\(version, privacy: .public)")
            return
        }

        didPostFirmwareVerificationNotification = true
        isAwaitingPostDfuFirmwareVerification = false
        isFirmwareUpdateRunning = false
        expectedFirmwareVerificationVersion = nil
        firmwareUpdateWatchdogTask?.cancel()
        firmwareUpdateWatchdogTask = nil
        clearFirmwareUpdateJournal()
        scheduleStableFirmwareVerification(version: version)
        firmwareLog.info("Firmware wirelessly verified version=\(version, privacy: .public)")
        DistributedNotificationCenter.default().postNotificationName(
            DoorLocalCommandBridge.firmwareVerifiedNotificationName,
            object: DoorLocalCommandBridge.appBundleIdentifier,
            userInfo: [DoorLocalCommandBridge.firmwareVersionKey: version],
            deliverImmediately: true
        )
    }

    func scheduleStableFirmwareVerification(version: String) {
        pendingStableFirmwareVerificationVersion = nil
        firmwareStableVerificationTask?.cancel()
        firmwareStableVerificationTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            await MainActor.run {
                guard let self else { return }
                self.firmwareStableVerificationTask = nil
                self.pendingStableFirmwareVerificationVersion = version
                // Force a new controller response instead of satisfying the
                // delayed check from the metadata cached immediately after DFU.
                self.hasCurrentFirmwareVersionSnapshot = false
                self.refreshWirelessControllerMetadataSnapshotRetry()
                self.requestWirelessStateNotificationSnapshotReplay()
            }
        }
    }

    @objc func handleLocalCommandNotification(_ notification: Notification) {
        guard let command = notification.userInfo?[DoorLocalCommandBridge.commandKey] as? String else { return }

        switch command {
        case "lock":
            lock()
        case "unlock":
            unlock()
        case "toggle":
            toggleLock()
        case "timeout":
            guard let rawSeconds = notification.userInfo?[DoorLocalCommandBridge.argumentKey] as? String,
                  let seconds = Int(rawSeconds) else { return }
            updateAutoLockSeconds(seconds)
        case "angles":
            guard let rawAngles = notification.userInfo?[DoorLocalCommandBridge.argumentKey] as? String else { return }
            let parts = rawAngles.split(separator: " ").compactMap { Int($0) }
            guard parts.count >= 2 else { return }
            updateServoAngles(ServoAngles(lockAngle: parts[0], unlockAngle: parts[1]))
        case "firmware":
            guard let rawPath = notification.userInfo?[DoorLocalCommandBridge.argumentKey] as? String else { return }
            let expectedVersion = notification.userInfo?[DoorLocalCommandBridge.expectedFirmwareVersionKey] as? String
            startFirmwareUpdate(from: URL(fileURLWithPath: rawPath), expectedVersion: expectedVersion)
        case "firmware-recover":
            guard let rawPath = notification.userInfo?[DoorLocalCommandBridge.argumentKey] as? String else { return }
            recoverFirmwareUpdate(from: URL(fileURLWithPath: rawPath))
        default:
            break
        }
    }
}
