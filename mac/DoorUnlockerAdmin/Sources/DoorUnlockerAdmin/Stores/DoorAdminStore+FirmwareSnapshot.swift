import CoreBluetooth
import DoorUnlockerShared
import Foundation

extension DoorAdminStore {
    func scheduleWirelessFirmwareVersionSnapshotRetry(after delay: TimeInterval = 0.42) {
        guard !hasCompleteWirelessControllerMetadataSnapshot else {
            wirelessFirmwareVersionSnapshotRetryTask?.cancel()
            wirelessFirmwareVersionSnapshotRetryTask = nil
            return
        }
        wirelessFirmwareVersionSnapshotRetryTask?.cancel()
        wirelessFirmwareVersionSnapshotRetryTask = Task { [weak self] in
            let nanoseconds = UInt64(max(0, delay) * 1_000_000_000)
            do { try await Task.sleep(nanoseconds: nanoseconds) } catch { return }
            await MainActor.run {
                guard let self else { return }
                self.wirelessFirmwareVersionSnapshotRetryTask = nil
                guard !self.hasCompleteWirelessControllerMetadataSnapshot else { return }
                switch DoorFirmwareSnapshotPolicy.action(
                    isControllerReady: self.isWirelessGattReady,
                    hasQueuedDoorCommand: self.hasQueuedWirelessDoorCommand,
                    hasInFlightDoorCommand: self.fastDoorCommandInFlight != nil,
                    hasControllerSettingOperation: self.isApplyingControllerSetting
                ) {
                case .stop:
                    return
                case .deferUntilCommandCompletes:
                    self.scheduleWirelessFirmwareVersionSnapshotRetry(after: 0.25)
                case .request:
                    self.requestWirelessStateNotificationSnapshotReplay()
                }
            }
        }
    }

    func requestWirelessStateNotificationSnapshotReplay() {
        guard !hasCompleteWirelessControllerMetadataSnapshot else { return }
        guard isWirelessDoorCommandReady,
              !wirelessControllerNonceHandoffGate.isInFlight,
              !wirelessLinkAuthenticationInFlight,
              pendingWirelessWriteIntents.isEmpty else {
            scheduleWirelessStateSnapshotFallbackRead(after: 0.35)
            scheduleWirelessFirmwareVersionSnapshotRetry(after: 0.35)
            return
        }

        guard let peripheral, let commandCharacteristic else {
            readStateIfPossible()
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        guard let generation = wirelessStateSnapshotRequestGate.begin(at: now, minimumInterval: 0.8) else {
            scheduleWirelessFirmwareVersionSnapshotRetry(after: 0.35)
            return
        }
        wirelessStateSnapshotRequestTimeoutTask?.cancel()
        wirelessStateSnapshotRequestTimeoutTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(750)) } catch { return }
            await MainActor.run {
                guard let self,
                      self.wirelessStateSnapshotRequestGate.expire(generation: generation) else { return }
                self.wirelessStateSnapshotRequestTimeoutTask = nil
            }
        }

        let payload = Data("snapshot".utf8)
        if commandCharacteristic.properties.contains(.write) {
            peripheral.writeValue(payload, for: commandCharacteristic, type: .withResponse)
        } else if commandCharacteristic.properties.contains(.writeWithoutResponse),
                  peripheral.canSendWriteWithoutResponse {
            peripheral.writeValue(payload, for: commandCharacteristic, type: .withoutResponse)
        } else {
            readStateIfPossible()
            return
        }
        recordRuntimeTelemetry("controller_snapshot_requested", once: false)
        scheduleWirelessFirmwareVersionSnapshotRetry(after: 1.2)
    }

    var hasCompleteWirelessControllerMetadataSnapshot: Bool {
        controllerFreshness.hasCompleteMetadataSnapshot(
            hasCurrentFirmwareVersion: hasCurrentFirmwareVersionSnapshot
        )
    }

    func refreshWirelessControllerMetadataSnapshotRetry() {
        if hasCompleteWirelessControllerMetadataSnapshot {
            wirelessFirmwareVersionSnapshotRetryTask?.cancel()
            wirelessFirmwareVersionSnapshotRetryTask = nil
        } else if isWirelessGattReady {
            scheduleWirelessFirmwareVersionSnapshotRetry(after: 0.35)
        }
    }
}
