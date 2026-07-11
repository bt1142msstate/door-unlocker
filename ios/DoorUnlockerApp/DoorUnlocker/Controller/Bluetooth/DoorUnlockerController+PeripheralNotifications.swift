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
    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor in
            guard isCurrentPeripheral(peripheral) else { return }
            guard characteristic.uuid == stateUUID || characteristic.uuid == controlUUID else { return }

            if let error {
                if characteristic.uuid == controlUUID, isReady, !isDoorCommandReady {
                    lastError = nil
                    startSecureLinkWatchdogIfNeeded()
                } else {
                    lastError = error.localizedDescription
                }
                return
            }

            if characteristic.uuid == stateUUID, characteristic.isNotifying {
#if DEBUG
                recordStartupTelemetry("state_notify_enabled")
#endif
                scheduleStartupCriticalSnapshot(after: .milliseconds(20))
                enableControlNotificationsIfPossible(on: peripheral)
                scheduleStateSnapshotFallbackRead()
                scheduleFirmwareVersionSnapshotRetry()
                return
            }

            if characteristic.uuid == controlUUID, characteristic.isNotifying {
#if DEBUG
                recordStartupTelemetry("control_notify_enabled")
#endif
                if proximityUnlockArmedAt != nil {
                    peripheral.readRSSI()
                }
                scheduleControlNonceRecoveryIfNeeded(after: .milliseconds(60))
                if isReady, !isDoorCommandReady {
                    startSecureLinkWatchdogIfNeeded()
                }
            }
        }
    }
}
