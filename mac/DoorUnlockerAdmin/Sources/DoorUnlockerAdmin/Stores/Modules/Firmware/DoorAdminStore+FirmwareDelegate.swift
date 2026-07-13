import CoreBluetooth
import DoorUnlockerCore
import DoorUnlockerDFU
import DoorUnlockerShared
import Foundation
import os

extension DoorAdminStore: DoorFirmwareDfuManagerDelegate {
    func firmwareDfuManagerDidSelectBootloader(name: String, packageProfile: String) {
        recordRuntimeTelemetry(
            "firmware_bootloader_selected",
            details: "name=\(name) profile=\(packageProfile)",
            once: false
        )
    }

    func firmwareDfuManagerDidUpdate(_ update: DoorFirmwareDfuUpdate) {
        firmwareLog.info("DFU status=\(update.status, privacy: .public) progress=\(update.progress ?? -1, privacy: .public)")
        recordRuntimeTelemetry(
            "firmware_update_status",
            details: "\(update.status) progress=\(update.progress ?? -1)",
            once: false
        )
        firmwareUpdateStatus = update.status
        firmwareUpdateProgress = update.progress
        firmwareUpdateEstimatedSecondsRemaining = update.estimatedSecondsRemaining
        if let progress = update.progress {
            updateFirmwareUpdateJournal(phase: .uploading, progress: progress)
        }
    }

    func firmwareDfuManagerDidDetectControllerFirmware() {
        firmwareUpdateStatus = "Controller firmware found. Reconnecting..."
        firmwareUpdateProgress = nil
        firmwareUpdateEstimatedSecondsRemaining = nil
        firmwareUpdateEntryCommandSent = false
        updateFirmwareUpdateJournal(phase: .verifying)
        firmwareDfuStartFallbackTask?.cancel()
        firmwareDfuStartFallbackTask = nil
        schedulePostDfuVerificationWatchdog()
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
        firmwareUpdateEstimatedSecondsRemaining = nil
        if expectedFirmwareVerificationVersion != nil {
            isAwaitingPostDfuFirmwareVerification = true
            didPostFirmwareVerificationNotification = false
        }
        schedulePostDfuVerificationWatchdog()
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
        let shouldAutomaticallyRetry = canAutomaticallyRetryFirmwareUpdate(after: message)
        if shouldAutomaticallyRetry {
            updateFirmwareUpdateJournal(phase: .paused, error: message)
        } else {
            clearFirmwareUpdateJournal()
        }
        firmwareUpdateStatus = shouldAutomaticallyRetry
            ? "Firmware update paused"
            : "Firmware update failed"
        firmwareUpdateProgress = nil
        firmwareUpdateEstimatedSecondsRemaining = nil
        isFirmwareUpdateRunning = false
        lastError = shouldAutomaticallyRetry
            ? "Firmware update paused. It will resume after reconnecting."
            : message
        if shouldAutomaticallyRetry {
            scheduleInterruptedFirmwareUpdateRetry()
        }
        scanBluetooth()
    }

    func schedulePostDfuVerificationWatchdog() {
        firmwareUpdateWatchdogTask?.cancel()
        firmwareUpdateWatchdogTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            await MainActor.run {
                guard let self, self.isFirmwareUpdateRunning else { return }
                self.firmwareUpdateWatchdogTask = nil
                self.isFirmwareUpdateRunning = false
                self.isAwaitingPostDfuFirmwareVerification = false
                self.firmwareUpdateStatus = "Firmware verification paused"
                self.firmwareUpdateProgress = nil
                self.lastError = "The upload finished, but the controller did not report its firmware version. Verification will resume after reconnecting."
                self.updateFirmwareUpdateJournal(phase: .paused, error: self.lastError)
                self.scheduleInterruptedFirmwareUpdateRetry()
                self.scanBluetooth()
            }
        }
    }
}
