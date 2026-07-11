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
    func schedulePostReadySync() {
        postReadySyncTask?.cancel()
        postReadySyncTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            await MainActor.run {
                guard let self, self.isReady else { return }
                self.syncLockNameIfReady()
                self.syncDeviceDisplayNameIfReady()
                self.postReadySyncTask = nil
            }
        }
    }

    func cancelPostReadySync() {
        postReadySyncTask?.cancel()
        postReadySyncTask = nil
    }

    func scheduleStateSnapshotFallbackRead(delay: Duration = .milliseconds(150)) {
        stateSnapshotFallbackTask?.cancel()
        let generation = stateUpdateGeneration
        stateSnapshotFallbackTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            await MainActor.run {
                guard let self,
                      self.stateUpdateGeneration == generation,
                      self.connectionState == "Ready",
                      self.peripheral?.state == .connected,
                      self.stateCharacteristic != nil else {
                    return
                }

                self.stateSnapshotFallbackTask = nil
                self.requestStateNotificationSnapshotReplay()
            }
        }
    }

    func startRSSIMonitoringIfNeeded() {
        guard rssiReadTask == nil else { return }

        rssiReadTask = Task { [weak self] in
            while !Task.isCancelled {
                await MainActor.run {
                    guard let self,
                          self.peripheral?.state == .connected else {
                        return
                    }

                    self.peripheral?.readRSSI()
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stopRSSIMonitoring() {
        rssiReadTask?.cancel()
        rssiReadTask = nil
        lockZoneBluetoothRSSI = nil
    }

    func startSecureLinkWatchdogIfNeeded() {
        guard secureLinkWatchdogTask == nil,
              needsFreshSecureNonce else { return }

        secureLinkWatchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                let action = await MainActor.run { () -> DoorCommandPreparationRecoveryAction in
                    guard let self else { return .idle }
                    return DoorCommandPreparationRecoveryPolicy.action(
                        needsFreshNonce: self.needsFreshSecureNonce,
                        hasQueuedCommand: self.pendingFreshNonceDoorCommand != nil,
                        completedNonceRequests: self.queuedDoorCommandNonceRequestCount
                    )
                }

                switch action {
                case .idle:
                    break
                case .requestNonce:
                    await MainActor.run {
                        guard let self,
                              self.needsFreshSecureNonce,
                              self.peripheral != nil,
                              self.controlCharacteristic != nil else {
                            return
                        }

                        if self.pendingFreshNonceDoorCommand != nil {
                            self.queuedDoorCommandNonceRequestCount += 1
                        } else {
                            self.queuedDoorCommandNonceRequestCount = 0
                        }
                        self.requestFreshSecureControlNonce()
                    }
                case .reconnect:
                    await MainActor.run {
                        self?.recoverStalledQueuedDoorCommandLink()
                    }
                }

                guard action == .requestNonce else { break }
                try? await Task.sleep(for: .milliseconds(500))
            }

            await MainActor.run {
                self?.secureLinkWatchdogTask = nil
            }
        }
    }

    func recoverStalledQueuedDoorCommandLink() {
        guard pendingFreshNonceDoorCommand != nil else {
            queuedDoorCommandNonceRequestCount = 0
            return
        }

        queuedDoorCommandNonceRequestCount = 0
        stopDoorCommandTransportRecovery()
#if DEBUG
        recordStartupTelemetry("door_command_link_recovery", details: connectionState, once: false)
#endif
        lastError = nil
        invalidatePreparedFastDoorCommandPayloads(clearNonce: true)
        resetLinkAuthentication()

        guard let peripheral, let central else {
            prepareConnectionForQueuedDoorCommand()
            return
        }

        switch peripheral.state {
        case .connected, .connecting, .disconnecting:
            connectionState = "Reconnecting"
            central.cancelPeripheralConnection(peripheral)
            scheduleReconnectCheck(after: Self.fastKnownControllerRetryDelay)
        case .disconnected:
            prepareConnectionForQueuedDoorCommand()
        @unknown default:
            prepareConnectionForQueuedDoorCommand()
        }
    }

    var needsFreshSecureNonce: Bool {
        isReady &&
            !hasFastCommandNonce &&
            !isDoorCommandReady &&
            ((pendingFirmwareUpdatePackageURL != nil && !firmwareUpdateEntryCommandSent) ||
                pendingFreshNonceDoorCommand != nil ||
                pendingSystemCommand != nil ||
                needsLinkAuthentication ||
                needsFastCommandPreparation)
    }

    var needsLinkAuthentication: Bool {
        !hasAuthenticatedCurrentLink &&
            !linkAuthenticationInFlight &&
            pendingFreshNonceDoorCommand == nil &&
            pendingSystemCommand == nil &&
            pendingFirmwareUpdatePackageURL == nil
    }

    var needsFastCommandPreparation: Bool {
        hasAuthenticatedCurrentLink &&
            pendingFreshNonceDoorCommand == nil &&
            pendingSystemCommand == nil &&
            pendingFirmwareUpdatePackageURL == nil &&
            !hasPreparedFastDoorCommandPayloads
    }
}
