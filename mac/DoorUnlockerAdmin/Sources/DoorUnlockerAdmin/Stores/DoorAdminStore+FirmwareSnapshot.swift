import CoreBluetooth
import Foundation

extension DoorAdminStore {
    func scheduleWirelessFirmwareVersionSnapshotRetry(after delay: TimeInterval = 0.42) {
        guard status.firmwareVersion == "Unknown" || firmwareUpdateStatus == "Update complete. Verifying..." else {
            return
        }
        wirelessFirmwareVersionSnapshotRetryTask?.cancel()
        let generation = wirelessStateUpdateGeneration
        wirelessFirmwareVersionSnapshotRetryTask = Task { [weak self] in
            let nanoseconds = UInt64(max(0, delay) * 1_000_000_000)
            do { try await Task.sleep(nanoseconds: nanoseconds) } catch { return }
            await MainActor.run {
                guard let self,
                      self.isWirelessGattReady,
                      self.wirelessStateUpdateGeneration == generation || self.status.firmwareVersion == "Unknown" || self.firmwareUpdateStatus == "Update complete. Verifying..." else {
                    return
                }

                self.wirelessFirmwareVersionSnapshotRetryTask = nil
                guard self.status.firmwareVersion == "Unknown" || self.firmwareUpdateStatus == "Update complete. Verifying..." else {
                    return
                }

                self.requestWirelessStateNotificationSnapshotReplay()
            }
        }
    }

    func requestWirelessStateNotificationSnapshotReplay() {
        // Re-enabling state notifications makes the controller replay its full
        // startup snapshot. Repeating that fallback can bury command confirmations
        // and disrupt other connected clients, so recovery is read-only.
        readStateIfPossible()
    }
}
