import CoreBluetooth
import DoorUnlockerCore
import DoorUnlockerDFU
import DoorUnlockerShared
import Foundation
import os

extension DoorAdminStore {
    func startFirmwareUpdate(from packageURL: URL, expectedVersion: String? = nil) {
        firmwareLog.info("Firmware update requested from \(packageURL.path, privacy: .public)")
        guard !isFirmwareUpdateRunning else {
            firmwareUpdateStatus = "Firmware update already running"
            lastError = "A firmware update is already in progress."
            firmwareLog.error("Ignored firmware update request because one is already running")
            return
        }
        guard packageURL.pathExtension.localizedCaseInsensitiveCompare("zip") == .orderedSame else {
            lastError = "Choose a firmware .zip package."
            return
        }

        do {
            let localPackageURL = try copyFirmwarePackageToTemporaryLocation(from: packageURL)
            expectedFirmwareVerificationVersion = expectedVersion
            isAwaitingPostDfuFirmwareVerification = false
            didPostFirmwareVerificationNotification = false
            startFirmwareUpdate(packageURL: localPackageURL)
        } catch {
            expectedFirmwareVerificationVersion = nil
            isAwaitingPostDfuFirmwareVerification = false
            didPostFirmwareVerificationNotification = false
            lastError = error.localizedDescription
            firmwareUpdateStatus = "Could not prepare firmware package"
            firmwareUpdateProgress = nil
            isFirmwareUpdateRunning = false
        }
    }

    func recoverFirmwareUpdate(from packageURL: URL) {
        firmwareLog.info("Firmware recovery upload requested from \(packageURL.path, privacy: .public)")
        guard !isFirmwareUpdateRunning else {
            firmwareUpdateStatus = "Firmware update already running"
            lastError = "A firmware update is already in progress."
            return
        }
        guard packageURL.pathExtension.localizedCaseInsensitiveCompare("zip") == .orderedSame else {
            lastError = "Choose a firmware .zip package."
            return
        }

        do {
            let localPackageURL = try copyFirmwarePackageToTemporaryLocation(from: packageURL)
            pendingFirmwareUpdatePackageURL = nil
            firmwareUpdateStatus = "Recovering firmware update"
            firmwareUpdateProgress = nil
            isFirmwareUpdateRunning = true
            lastError = nil
            switchUSBToWirelessFirmwareUpdateIfNeeded()
            beginFirmwareDfuUpload(after: localPackageURL)
        } catch {
            lastError = error.localizedDescription
            firmwareUpdateStatus = "Could not prepare firmware package"
            firmwareUpdateProgress = nil
            isFirmwareUpdateRunning = false
        }
    }

    func copyFirmwarePackageToTemporaryLocation(from url: URL) throws -> URL {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("DoorUnlockerFirmware", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let packageURL = destination.appendingPathComponent("DoorUnlockerXiao-dfu.zip")
        if FileManager.default.fileExists(atPath: packageURL.path) {
            try FileManager.default.removeItem(at: packageURL)
        }
        try FileManager.default.copyItem(at: url, to: packageURL)
        return packageURL
    }

    func startFirmwareUpdate(packageURL: URL) {
        pendingFirmwareUpdatePackageURL = packageURL
        firmwareUpdateEntryCommandSent = false
        firmwareDfuStartFallbackTask?.cancel()
        firmwareDfuStartFallbackTask = nil
        firmwareUpdateStatus = "Preparing firmware update"
        firmwareUpdateProgress = nil
        isFirmwareUpdateRunning = true
        lastError = nil
        let packagePath = packageURL.path
        let usbConnected = isConnected
        let wirelessReady = isWirelessReady
        let canUseWireless = canUseWirelessFallback
        firmwareLog.info(
            "Start requested package=\(packagePath, privacy: .public) usb=\(usbConnected, privacy: .public) wirelessReady=\(wirelessReady, privacy: .public) canUseWireless=\(canUseWireless, privacy: .public)"
        )
        scheduleFirmwareUpdateCommandWatchdog()

        switchUSBToWirelessFirmwareUpdateIfNeeded()

        if isWirelessReady {
            firmwareLog.info("Wireless already ready; sending OTA request")
            _ = sendPendingFirmwareUpdateCommandIfReady()
        } else if canUseWirelessFallback {
            firmwareUpdateStatus = "Connecting wirelessly"
            firmwareLog.info("Queueing OTA request while wireless connects")
            queueWirelessCommand("ENTER_OTA_DFU", intent: .firmwareUpdate(packageURL))
            scanBluetooth()
        } else {
            pendingFirmwareUpdatePackageURL = nil
            expectedFirmwareVerificationVersion = nil
            isAwaitingPostDfuFirmwareVerification = false
            didPostFirmwareVerificationNotification = false
            firmwareUpdateStatus = "Pair this Mac over USB-C first"
            firmwareUpdateProgress = nil
            isFirmwareUpdateRunning = false
            firmwareUpdateWatchdogTask?.cancel()
            firmwareUpdateWatchdogTask = nil
            lastError = "This Mac is not trusted for wireless firmware updates yet. Connect over USB-C once, then try again."
        }
    }

    func scheduleFirmwareUpdateCommandWatchdog() {
        firmwareUpdateWatchdogTask?.cancel()
        firmwareUpdateWatchdogTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 25_000_000_000) } catch { return }
            await MainActor.run {
                guard let self,
                      self.isFirmwareUpdateRunning,
                      self.pendingFirmwareUpdatePackageURL != nil else {
                    return
                }

                self.firmwareLog.error("Firmware update timed out before controller entered DFU mode")
                self.pendingFirmwareUpdatePackageURL = nil
                self.firmwareUpdateEntryCommandSent = false
                self.expectedFirmwareVerificationVersion = nil
                self.isAwaitingPostDfuFirmwareVerification = false
                self.didPostFirmwareVerificationNotification = false
                self.firmwareDfuStartFallbackTask?.cancel()
                self.firmwareDfuStartFallbackTask = nil
                if case .firmwareUpdate = self.pendingWirelessCommandIntent {
                    self.pendingWirelessCommandText = nil
                    self.pendingWirelessPredictedCommand = nil
                    self.pendingWirelessCommandIntent = nil
                }
                self.firmwareUpdateStatus = "Firmware update timed out"
                self.firmwareUpdateProgress = nil
                self.isFirmwareUpdateRunning = false
                self.lastError = "The controller did not enter firmware update mode. Try again near the controller or use USB-C recovery."
                self.firmwareUpdateWatchdogTask = nil
                self.scanBluetooth()
            }
        }
    }

    func switchUSBToWirelessFirmwareUpdateIfNeeded() {
        guard isConnected || isUSBConnectInFlight else { return }

        firmwareLog.info("Closing USB session so firmware update can use BLE")
        cancelUSBStartupSync()
        connection?.close()
        connection = nil
        isConnected = false
        isUSBConnectInFlight = false
        lastUSBStatusSyncAt = nil
        didTrustMacDuringUSBSession = false
        status = statusRemovingLocalUSBConnection(status)
        message = "Switching to wireless update"
        ensureBluetoothCentral()
    }
}
