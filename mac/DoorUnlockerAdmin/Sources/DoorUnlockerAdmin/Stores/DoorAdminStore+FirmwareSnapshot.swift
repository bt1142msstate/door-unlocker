import CoreBluetooth
import Foundation

extension DoorAdminStore {
    func scheduleWirelessFirmwareVersionSnapshotRetry(after delay: TimeInterval = 0.42) {
        wirelessFirmwareVersionSnapshotRetryTask?.cancel()
        let generation = wirelessStateUpdateGeneration
        wirelessFirmwareVersionSnapshotRetryTask = Task { [weak self] in
            let nanoseconds = UInt64(max(0, delay) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
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
        guard let peripheral,
              let stateCharacteristic,
              stateCharacteristic.properties.contains(.notify) || stateCharacteristic.properties.contains(.indicate) else {
            readStateIfPossible()
            return
        }

        if stateCharacteristic.isNotifying {
            peripheral.setNotifyValue(false, for: stateCharacteristic)
            Task { [weak self, weak peripheral, weak stateCharacteristic] in
                try? await Task.sleep(nanoseconds: 90_000_000)
                await MainActor.run {
                    guard let self,
                          let peripheral,
                          let stateCharacteristic,
                          self.isCurrentPeripheral(peripheral),
                          self.stateCharacteristic?.uuid == stateCharacteristic.uuid,
                          peripheral.state == .connected else {
                        return
                    }

                    peripheral.setNotifyValue(true, for: stateCharacteristic)
                }
            }
        } else {
            peripheral.setNotifyValue(true, for: stateCharacteristic)
        }
    }
}
