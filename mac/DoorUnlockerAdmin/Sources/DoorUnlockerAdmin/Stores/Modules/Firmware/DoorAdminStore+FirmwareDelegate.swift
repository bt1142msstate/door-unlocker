import CoreBluetooth
import DoorUnlockerCore
import DoorUnlockerDFU
import DoorUnlockerShared
import Foundation
import os

extension DoorAdminStore: DoorFirmwareDfuManagerDelegate {
    func firmwareDfuManagerDidUpdate(_ update: DoorFirmwareDfuUpdate) {
        firmwareLog.info("DFU status=\(update.status, privacy: .public) progress=\(update.progress ?? -1, privacy: .public)")
        recordRuntimeTelemetry(
            "firmware_update_status",
            details: "\(update.status) progress=\(update.progress ?? -1)",
            once: false
        )
        firmwareUpdateStatus = update.status
        firmwareUpdateProgress = update.progress
        if let progress = update.progress {
            updateFirmwareUpdateJournal(phase: .uploading, progress: progress)
        }
    }

    func firmwareDfuManagerDidDetectControllerFirmware() {
        firmwareUpdateStatus = "Controller firmware found. Reconnecting..."
        firmwareUpdateProgress = nil
        isFirmwareUpdateRunning = false
        firmwareUpdateEntryCommandSent = false
        updateFirmwareUpdateJournal(phase: .verifying)
        firmwareDfuStartFallbackTask?.cancel()
        firmwareDfuStartFallbackTask = nil
        scanBluetooth()
    }

    func firmwareDfuManagerDidFinish() {
        firmwareLog.info("DFU finished; verifying firmware version")
        recordRuntimeTelemetry("firmware_update_uploaded", once: false)
        firmwareUpdateWatchdogTask?.cancel()
        firmwareUpdateWatchdogTask = nil
        firmwareDfuStartFallbackTask?.cancel()
        firmwareDfuStartFallbackTask = nil
        firmwareUpdateEntryCommandSent = false
        updateFirmwareUpdateJournal(phase: .verifying, progress: 100)
        firmwareUpdateStatus = "Update complete. Verifying..."
        firmwareUpdateProgress = 100
        isFirmwareUpdateRunning = false
        if expectedFirmwareVerificationVersion != nil {
            isAwaitingPostDfuFirmwareVerification = true
            didPostFirmwareVerificationNotification = false
        }
        wirelessIdleDisconnectTask?.cancel()
        wirelessIdleDisconnectTask = nil
        Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 1_500_000_000) } catch { return }
            await MainActor.run {
                guard let self else { return }
                if self.isConnected {
                    self.refreshAll()
                } else {
                    self.scanBluetooth()
                }
            }
        }
    }

    func firmwareDfuManagerDidFail(_ message: String) {
        firmwareLog.error("DFU failed: \(message, privacy: .public)")
        recordRuntimeTelemetry("firmware_update_failed", details: message, once: false)
        firmwareUpdateWatchdogTask?.cancel()
        firmwareUpdateWatchdogTask = nil
        firmwareDfuStartFallbackTask?.cancel()
        firmwareDfuStartFallbackTask = nil
        pendingFirmwareUpdatePackageURL = nil
        firmwareUpdateEntryCommandSent = false
        isAwaitingPostDfuFirmwareVerification = false
        didPostFirmwareVerificationNotification = false
        updateFirmwareUpdateJournal(phase: .paused, error: message)
        let shouldAutomaticallyRetry = canAutomaticallyRetryFirmwareUpdate(after: message)
        firmwareUpdateStatus = shouldAutomaticallyRetry
            ? "Firmware update paused"
            : "Firmware update failed"
        firmwareUpdateProgress = nil
        isFirmwareUpdateRunning = false
        lastError = shouldAutomaticallyRetry
            ? "Firmware update paused. It will resume after reconnecting."
            : message
        if shouldAutomaticallyRetry {
            scheduleInterruptedFirmwareUpdateRetry()
        }
        scanBluetooth()
    }
}
