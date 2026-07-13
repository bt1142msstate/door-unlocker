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

extension DoorUnlockerController {
    var isFirmwareUpdateObservedFromAnotherDevice: Bool {
        observedFirmwareUpdate.isActive && !isFirmwareDfuTransportActive
    }

    var isFirmwareDfuTransportActive: Bool {
        DoorFirmwareTransportOwnership.isDfuTransportActive(
            isUpdateRunning: isFirmwareUpdateRunning,
            entryCommandSent: firmwareUpdateEntryCommandSent,
            hasPendingPackage: pendingFirmwareUpdatePackageURL != nil
        )
    }

    func observeFirmwareUpdateAnnouncement(updaterName: String?) {
        if isFirmwareDfuTransportActive {
            firmwareUpdateStatus = "Controller entering update mode"
            beginPendingFirmwareDfuUploadIfNeeded()
            return
        }

        observedFirmwareUpdate.begin(updaterName: updaterName)
        observedFirmwareUpdateTimeoutTask?.cancel()
        connectionState = "Updating firmware"
        firmwareUpdateStatus = updaterName.map { "Updating from \($0)" } ?? "Updating from another device"
        lastError = nil
        observedFirmwareUpdateTimeoutTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                let didExpire = await MainActor.run { () -> Bool in
                    guard let self else { return true }
                    self.observedFirmwareUpdate.tick()
                    if self.observedFirmwareUpdate.expire() {
                        self.observedFirmwareUpdateTimeoutTask = nil
                        self.firmwareUpdateStatus = "Ready"
                        self.connectionState = "Disconnected"
                        self.lastError = "The controller did not return after its firmware update."
                        self.scheduleReconnectCheck(after: Self.fastKnownControllerRetryDelay)
                        return true
                    }
                    return false
                }
                if didExpire { return }
            }
        }
    }

    func finishObservedFirmwareUpdate(version: String) {
        guard observedFirmwareUpdate.isActive else { return }
        observedFirmwareUpdate.finish()
        observedFirmwareUpdateTimeoutTask?.cancel()
        observedFirmwareUpdateTimeoutTask = nil
        firmwareUpdateStatus = "Update finished. Controller is on \(version)."
        lastError = nil
        scheduleFirmwareUpdateSuccessReset()
    }

    func startFirmwareUpdate(fromExternalPackageURL url: URL) {
        do {
            let localURL = try copyFirmwarePackageToTemporaryLocation(from: url)
            startFirmwareUpdate(packageURL: localURL)
        } catch {
            lastError = error.localizedDescription
            firmwareUpdateStatus = "Could not prepare firmware package"
            firmwareUpdateProgress = nil
            firmwareUpdateEstimatedSecondsRemaining = nil
            isFirmwareUpdateRunning = false
        }
    }

    func copyFirmwarePackageToTemporaryLocation(from url: URL) throws -> URL {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

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

    func startFirmwareUpdate(packageURL: URL, requiresSettingsUnlock: Bool = true) {
        guard !isFirmwareUpdateRunning else {
#if DEBUG
            recordStartupTelemetry("firmware_start_ignored_running", once: false)
#endif
            return
        }
        guard !requiresSettingsUnlock || areSettingsUnlocked else {
#if DEBUG
            recordStartupTelemetry("firmware_start_blocked_settings_locked", once: false)
#endif
            lastError = "Open settings with Face ID or passcode before updating firmware."
            return
        }

        guard packageURL.pathExtension.localizedCaseInsensitiveCompare("zip") == .orderedSame else {
#if DEBUG
            recordStartupTelemetry("firmware_start_blocked_not_zip", details: packageURL.pathExtension, once: false)
#endif
            lastError = "Choose a firmware .zip package."
            return
        }

        observedFirmwareUpdate.finish()
        observedFirmwareUpdateTimeoutTask?.cancel()
        observedFirmwareUpdateTimeoutTask = nil

#if DEBUG
        recordStartupTelemetry("firmware_start_pending", details: packageURL.lastPathComponent, once: false)
#endif
        cancelFirmwareUpdateSuccessReset()
        pendingFirmwareUpdatePackageURL = packageURL
        firmwareUpdateEntryCommandSent = false
        firmwareDfuStartFallbackTask?.cancel()
        firmwareDfuStartFallbackTask = nil
        firmwareUpdateStatus = "Preparing secure firmware update"
        firmwareUpdateProgress = nil
        firmwareUpdateEstimatedSecondsRemaining = nil
        isFirmwareUpdateRunning = true
        lastError = nil
        requestFirmwareUpdateNotificationAuthorizationIfNeeded()
        updatePendingFirmwareJournal(phase: .preparing)

        if !sendPendingFirmwareUpdateCommandIfReady() {
            requestControllerConnectionIfNeeded()
        }
    }

    @discardableResult
    func sendPendingFirmwareUpdateCommandIfReady() -> Bool {
        guard let packageURL = pendingFirmwareUpdatePackageURL else {
            return false
        }
        guard !firmwareUpdateEntryCommandSent else {
#if DEBUG
            recordStartupTelemetry("firmware_send_skipped_already_sent", once: false)
#endif
            return false
        }

        guard isReady else {
#if DEBUG
            recordStartupTelemetry("firmware_send_waiting_ready", details: connectionState, once: false)
#endif
            firmwareUpdateStatus = "Connecting to controller"
            requestControllerConnectionIfNeeded()
            return false
        }

        guard fastCommandNonce != nil else {
#if DEBUG
            recordStartupTelemetry("firmware_send_waiting_nonce", once: false)
#endif
            firmwareUpdateStatus = "Preparing secure command"
            requestFreshSecureControlNonce()
            return false
        }

#if DEBUG
        recordStartupTelemetry("firmware_send_enter_ota", once: false)
#endif
        firmwareUpdateStatus = "Requesting firmware update mode"
        updatePendingFirmwareJournal(phase: .requestingBootloader)
        if writeAuthenticatedCommand("ENTER_OTA_DFU", intent: .firmwareUpdate(packageURL)) {
#if DEBUG
            recordStartupTelemetry("firmware_send_enter_ota_written", once: false)
            if debugExpectedFirmwareVersion != nil {
                debugFirmwareAwaitingPostDfuVerification = true
                debugFirmwareVerifiedNotificationPosted = false
                recordStartupTelemetry("debug_firmware_waiting_wireless_verify", once: false)
            }
#endif
            firmwareUpdateEntryCommandSent = true
            stopSecureLinkWatchdog()
            return true
        }

#if DEBUG
        recordStartupTelemetry("firmware_send_enter_ota_failed", once: false)
#endif
        firmwareUpdateStatus = "Could not request firmware update mode"
        isFirmwareUpdateRunning = false
        pendingFirmwareUpdatePackageURL = nil
        firmwareUpdateEntryCommandSent = false
        firmwareUpdateEstimatedSecondsRemaining = nil
#if DEBUG
        debugFirmwareAwaitingPostDfuVerification = false
        debugFirmwareVerifiedNotificationPosted = false
#endif
        return false
    }

    func beginFirmwareDfuUpload(after packageURL: URL, detectsNormalControllerFirmware: Bool = false) {
        firmwareUpdateStatus = "Waiting for update bootloader"
        updatePendingFirmwareJournal(phase: .scanningForBootloader)
        firmwareUpdateProgress = nil
        firmwareUpdateEstimatedSecondsRemaining = nil
        firmwareDfuStartFallbackTask?.cancel()
        prepareControllerSessionForFirmwareDfu()
        firmwareDfuStartFallbackTask = Task { [weak self] in
            // CoreBluetooth cancellation is asynchronous. Give the normal
            // controller session time to release the peripheral before DFU scans.
            try? await Task.sleep(for: .milliseconds(650))
            await MainActor.run {
                guard let self, self.isFirmwareUpdateRunning else { return }
                self.firmwareDfuStartFallbackTask = nil
                self.firmwareDfuManager.start(
                    packageURL: packageURL,
                    signedPackageURL: self.bundledSignedFirmwarePackageURL,
                    detectsNormalControllerFirmware: detectsNormalControllerFirmware
                )
            }
        }
    }

    func resumeFirmwareDfuUpload(packageURL: URL, status: String) {
        cancelFirmwareUpdateSuccessReset()
        firmwareUpdateStatus = status
        firmwareUpdateProgress = nil
        firmwareUpdateEstimatedSecondsRemaining = nil
        isFirmwareUpdateRunning = true
        lastError = nil
        requestFirmwareUpdateNotificationAuthorizationIfNeeded()
        beginFirmwareDfuUpload(after: packageURL, detectsNormalControllerFirmware: true)
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
            try? await Task.sleep(for: .seconds(delay))
            await MainActor.run {
                guard let self,
                      self.isFirmwareUpdateRunning,
                      self.pendingFirmwareUpdatePackageURL != nil else {
                    return
                }

                self.beginPendingFirmwareDfuUploadIfNeeded()
            }
        }
    }
}
