import DoorUnlockerShared
import Foundation

extension DoorAdminStore {
    var isFirmwareUpdateObservedFromAnotherDevice: Bool {
        observedFirmwareUpdate.isActive && !isFirmwareUpdateRunning
    }

    func observeFirmwareUpdateAnnouncement(updaterName: String?) {
        if isFirmwareUpdateRunning {
            firmwareUpdateStatus = "Controller entering update mode"
            beginPendingFirmwareDfuUploadIfNeeded()
            return
        }

        observedFirmwareUpdate.begin(updaterName: updaterName)
        observedFirmwareUpdateTimeoutTask?.cancel()
        wirelessConnectionState = "Updating firmware"
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
                        self.wirelessConnectionState = "Idle"
                        self.lastError = "The controller did not return after its firmware update."
                        self.scheduleWirelessReconnect()
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
    }

    func clearObservedFirmwareUpdateBeforeLocalStart() {
        observedFirmwareUpdate.finish()
        observedFirmwareUpdateTimeoutTask?.cancel()
        observedFirmwareUpdateTimeoutTask = nil
    }
}
