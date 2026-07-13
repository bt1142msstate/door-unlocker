import CoreBluetooth
import CoreLocation
import DoorUnlockerDFU
import DoorUnlockerShared
import Foundation
import ActivityKit
import LocalAuthentication
import UIKit
import UserNotifications
import WidgetKit

extension DoorUnlockerController: DoorFirmwareDfuManagerDelegate {
    func firmwareDfuManagerDidUpdate(_ update: DoorFirmwareDfuUpdate) {
        firmwareUpdateStatus = update.status
        firmwareUpdateProgress = update.progress
        firmwareUpdateEstimatedSecondsRemaining = update.estimatedSecondsRemaining
        if let progress = update.progress {
            updatePendingFirmwareJournal(phase: .uploading, progress: progress)
        }
    }

    func firmwareDfuManagerDidDetectControllerFirmware() {
#if DEBUG
        recordStartupTelemetry("firmware_recovery_normal_mode_detected", once: false)
#endif
        firmwareUpdateStatus = "Controller firmware found. Reconnecting..."
        firmwareUpdateProgress = nil
        firmwareUpdateEstimatedSecondsRemaining = nil
        isFirmwareUpdateRunning = false
        firmwareUpdateEntryCommandSent = false
        autoBundledFirmwareUpdateAttemptedVersion = nil
        updatePendingFirmwareJournal(phase: .verifying)
        firmwareDfuStartFallbackTask?.cancel()
        firmwareDfuStartFallbackTask = nil
        scan()
    }

    func firmwareDfuManagerDidFinish() {
        cancelFirmwareUpdateSuccessReset()
        firmwareUpdateStatus = "Update complete. Verifying..."
        firmwareUpdateProgress = 100
        firmwareUpdateEstimatedSecondsRemaining = nil
        isFirmwareUpdateRunning = false
        firmwareUpdateEntryCommandSent = false
        updatePendingFirmwareJournal(phase: .verifying, progress: 100)
#if DEBUG
        if debugExpectedFirmwareVersion != nil {
            debugFirmwareAwaitingPostDfuVerification = true
            debugFirmwareVerifiedNotificationPosted = false
            recordStartupTelemetry("debug_firmware_waiting_wireless_verify", once: false)
        }
#endif
        firmwareDfuStartFallbackTask?.cancel()
        firmwareDfuStartFallbackTask = nil
        reconnectTimer?.invalidate()
        clearDiscoveredControllerCharacteristics()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            await MainActor.run {
                self?.scan()
                self?.scheduleStateSnapshotFallbackRead(delay: .milliseconds(700))
            }
        }
    }

    func firmwareDfuManagerDidFail(_ message: String) {
        cancelFirmwareUpdateSuccessReset()
        let canRecoverBundledUpdate = bundledFirmwarePackageURL != nil &&
            UserDefaults.standard.string(forKey: Self.pendingBundledFirmwareUpdateVersionKey)?.isEmpty == false
        let shouldAutomaticallyRetry = canRecoverBundledUpdate
            && canAutomaticallyRetryPendingFirmwareUpdate(after: message)
        firmwareUpdateStatus = shouldAutomaticallyRetry
            ? "Firmware update paused"
            : "Firmware update failed"
        firmwareUpdateProgress = nil
        firmwareUpdateEstimatedSecondsRemaining = nil
        isFirmwareUpdateRunning = false
        pendingFirmwareUpdatePackageURL = nil
        firmwareUpdateEntryCommandSent = false
        if shouldAutomaticallyRetry {
            autoBundledFirmwareUpdateAttemptedVersion = nil
        }
        if shouldAutomaticallyRetry {
            updatePendingFirmwareJournal(phase: .paused, error: message)
            scheduleInterruptedFirmwareUpdateRetry()
        } else {
            clearPendingBundledFirmwareUpdate()
        }
#if DEBUG
        debugFirmwareAwaitingPostDfuVerification = false
        debugFirmwareVerifiedNotificationPosted = false
#endif
        firmwareDfuStartFallbackTask?.cancel()
        firmwareDfuStartFallbackTask = nil
        lastError = shouldAutomaticallyRetry
            ? "Firmware update paused. It will resume after reconnecting."
            : message
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            await MainActor.run {
                self?.scan()
            }
        }
    }
}
