import CoreBluetooth
import DoorUnlockerCore
import DoorUnlockerDFU
import DoorUnlockerShared
import Foundation
import os

extension DoorAdminStore {
    func beginUSBFirmwareUpdateMode(packageURL: URL) {
        guard !isBusy else {
            firmwareUpdateStatus = "Controller is busy"
            firmwareUpdateProgress = nil
            isFirmwareUpdateRunning = false
            return
        }
        cancelUSBStartupSync()
        Task {
            await run("Firmware update") {
                firmwareUpdateStatus = "Requesting firmware update mode over USB-C"
                let lines = try await transact("app ota", until: ["APP_OK firmware_update=ota_dfu"], timeout: 4)
                appendLog(lines)
                pendingFirmwareUpdatePackageURL = nil
                beginFirmwareDfuUpload(after: packageURL)
            }
        }
    }

    @discardableResult
    func sendPendingFirmwareUpdateCommandIfReady() -> Bool {
        guard let packageURL = pendingFirmwareUpdatePackageURL else { return false }
        guard !firmwareUpdateEntryCommandSent else { return false }

        guard isWirelessReady else {
            firmwareUpdateStatus = "Connecting wirelessly"
            firmwareLog.info("OTA request waiting for wireless readiness")
            scanBluetooth()
            return false
        }

        guard fastCommandNonce != nil else {
            firmwareUpdateStatus = "Preparing secure command"
            firmwareLog.info("OTA request waiting for secure nonce")
            requestWirelessControlNonce()
            return false
        }

        firmwareUpdateStatus = "Requesting firmware update mode"
        updateFirmwareUpdateJournal(phase: .requestingBootloader)
        firmwareLog.info("Sending secure OTA DFU entry command")
        switch sendWirelessCommandText("ENTER_OTA_DFU", intent: .firmwareUpdate(packageURL)) {
        case .sent:
            firmwareUpdateEntryCommandSent = true
            stopSecureLinkWatchdog()
            pendingWirelessCommandText = nil
            pendingWirelessPredictedCommand = nil
            pendingWirelessCommandIntent = nil
            firmwareLog.info("Secure OTA DFU entry command queued/written")
            return true
        case .queued:
            firmwareUpdateStatus = "Preparing secure command"
            startSecureLinkWatchdogIfNeeded()
            return false
        case .failed:
            break
        }

        firmwareUpdateStatus = "Could not request firmware update mode"
        firmwareUpdateProgress = nil
        isFirmwareUpdateRunning = false
        pendingFirmwareUpdatePackageURL = nil
        isAwaitingPostDfuFirmwareVerification = false
        didPostFirmwareVerificationNotification = false
        firmwareUpdateEntryCommandSent = false
        updateFirmwareUpdateJournal(phase: .paused, error: "Could not request firmware update mode")
        scheduleInterruptedFirmwareUpdateRetry()
        firmwareLog.error("Secure OTA DFU entry command failed before write")
        return false
    }

    func beginFirmwareDfuUpload(after packageURL: URL, detectsNormalControllerFirmware: Bool = false) {
        firmwareUpdateStatus = "Waiting for update bootloader"
        updateFirmwareUpdateJournal(phase: .scanningForBootloader)
        firmwareUpdateProgress = nil
        firmwareUpdateWatchdogTask?.cancel()
        firmwareUpdateWatchdogTask = nil
        firmwareDfuStartFallbackTask?.cancel()
        firmwareDfuStartFallbackTask = nil
        firmwareLog.info("Starting Nordic DFU manager package=\(packageURL.path, privacy: .public)")
        prepareWirelessSessionForFirmwareDfu()
        firmwareDfuManager.start(
            packageURL: packageURL,
            detectsNormalControllerFirmware: detectsNormalControllerFirmware
        )
    }

    func beginPendingFirmwareDfuUploadIfNeeded() {
        guard let packageURL = pendingFirmwareUpdatePackageURL else { return }
        pendingFirmwareUpdatePackageURL = nil
        firmwareUpdateEntryCommandSent = false
        beginFirmwareDfuUpload(after: packageURL)
    }

    func scheduleFirmwareDfuStartFallback(after delay: TimeInterval = 0.8) {
        guard pendingFirmwareUpdatePackageURL != nil else { return }

        firmwareDfuStartFallbackTask?.cancel()
        firmwareDfuStartFallbackTask = Task { [weak self] in
            let nanoseconds = UInt64(max(0, delay) * 1_000_000_000)
            do { try await Task.sleep(nanoseconds: nanoseconds) } catch { return }
            await MainActor.run {
                guard let self,
                      self.isFirmwareUpdateRunning,
                      self.pendingFirmwareUpdatePackageURL != nil else {
                    return
                }

                self.firmwareLog.info("Starting DFU from OTA entry write fallback")
                self.beginPendingFirmwareDfuUploadIfNeeded()
            }
        }
    }
}
