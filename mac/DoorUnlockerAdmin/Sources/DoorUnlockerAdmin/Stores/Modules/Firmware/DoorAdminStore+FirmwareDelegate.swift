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
    }

    func firmwareDfuManagerDidDetectControllerFirmware() {
        firmwareUpdateStatus = "Controller firmware found. Reconnecting..."
        firmwareUpdateProgress = nil
        isFirmwareUpdateRunning = false
        firmwareUpdateEntryCommandSent = false
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
        expectedFirmwareVerificationVersion = nil
        isAwaitingPostDfuFirmwareVerification = false
        didPostFirmwareVerificationNotification = false
        firmwareUpdateStatus = "Firmware update failed"
        firmwareUpdateProgress = nil
        isFirmwareUpdateRunning = false
        lastError = message
        scanBluetooth()
    }
}
