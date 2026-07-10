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
    func applyKnownLastUnlock(
        _ unlockedAt: Date,
        deviceIdentifier: String? = nil,
        deviceName: String? = nil,
        replaceDeviceMetadata: Bool = false,
        updateLockZone: Bool = false
    ) {
        if let lastUnlockAt, unlockedAt < lastUnlockAt.addingTimeInterval(-1) {
            return
        }

        lastUnlockAt = unlockedAt
        UserDefaults.standard.set(unlockedAt.timeIntervalSince1970, forKey: Self.lastUnlockAtKey)
        applyLastUnlockDeviceMetadata(
            identifier: deviceIdentifier,
            name: deviceName,
            replaceMissing: replaceDeviceMetadata
        )

        if updateLockZone {
            requestCurrentLocation(for: .updateLockZoneAfterUnlock)
        }
    }

    func applyLastUnlockDeviceMetadata(identifier: String?, name: String?, replaceMissing: Bool) {
        if let identifier {
            let sanitizedIdentifier = Self.sanitizedTrustedDeviceIdentifier(identifier)
            lastUnlockDeviceIdentifier = sanitizedIdentifier
            if sanitizedIdentifier.isEmpty {
                UserDefaults.standard.removeObject(forKey: Self.lastUnlockDeviceIdentifierKey)
            } else {
                UserDefaults.standard.set(sanitizedIdentifier, forKey: Self.lastUnlockDeviceIdentifierKey)
            }
        } else if replaceMissing {
            lastUnlockDeviceIdentifier = ""
            UserDefaults.standard.removeObject(forKey: Self.lastUnlockDeviceIdentifierKey)
        }

        if let name {
            let sanitizedName = DoorControllerPolicy.sanitizedName(name, fallback: "Device")
            lastUnlockDeviceName = sanitizedName
            if sanitizedName.isEmpty {
                UserDefaults.standard.removeObject(forKey: Self.lastUnlockDeviceNameKey)
            } else {
                UserDefaults.standard.set(sanitizedName, forKey: Self.lastUnlockDeviceNameKey)
            }
        } else if replaceMissing {
            lastUnlockDeviceName = ""
            UserDefaults.standard.removeObject(forKey: Self.lastUnlockDeviceNameKey)
        }
    }

    func refreshControllerLastUnlockSoon() {
        hasRequestedControllerLastUnlock = false

        Task { [weak self] in
            for delayNanoseconds in [350_000_000, 1_000_000_000, 2_000_000_000] as [UInt64] {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
                guard !Task.isCancelled else { return }

                let didRequest = await MainActor.run {
                    guard let self else { return true }
                    guard !self.hasRequestedControllerLastUnlock else { return true }
                    self.requestControllerLastUnlockIfReady()
                    return self.hasRequestedControllerLastUnlock
                }

                if didRequest {
                    return
                }
            }
        }
    }

    func shouldIgnoreStaleDoorState(_ incomingState: String) -> Bool {
        guard let optimisticDoorCommand, let optimisticDoorCommandSentAt else {
            return false
        }

        let elapsedSeconds = Date().timeIntervalSince(optimisticDoorCommandSentAt)
        guard elapsedSeconds < 12 else {
            clearOptimisticDoorCommand()
            return false
        }

        switch (optimisticDoorCommand, servoState, incomingState) {
        case (.unlock, "unlocking", "locked"),
             (.lock, "locking", "unlocked"):
            return true
        default:
            return false
        }
    }

    func reconcileOptimisticDoorCommand(with incomingState: String) {
        guard let optimisticDoorCommand else { return }

        switch (optimisticDoorCommand, incomingState) {
        case (.unlock, "unlocking"),
             (.lock, "locking"):
            optimisticDoorCommandAcknowledged = true
            lastError = nil
        case (.unlock, "unlocked"):
            let origin = optimisticDoorCommandOrigin
            if let optimisticDoorCommandSentAt {
                applyKnownLastUnlock(
                    optimisticDoorCommandSentAt,
                    deviceName: deviceDisplayName,
                    updateLockZone: true
                )
            }
            lastError = nil
            clearOptimisticDoorCommand()
            if origin == .proximity {
                endProximityUnlockBackgroundTask()
            }
        case (.lock, "locked"):
            let origin = optimisticDoorCommandOrigin
            lastError = nil
            clearOptimisticDoorCommand()
            if origin == .proximity {
                endProximityUnlockBackgroundTask()
            }
        case (_, "rejected"),
             (_, "unpaired"),
             (_, "pairing_locked"):
            let origin = optimisticDoorCommandOrigin
            clearOptimisticDoorCommand()
            if origin == .proximity {
                endProximityUnlockBackgroundTask()
            }
        default:
            break
        }
    }

    func handleControllerRejectedState() {
        clearRemoteSettingApplying()

        if let inFlightControllerSetting {
            failControllerSetting(inFlightControllerSetting, reason: "Controller rejected the setting")
        }

        if let optimisticDoorCommand {
            let origin = optimisticDoorCommandOrigin
            let restoredState = stableRestoredDoorState()
            clearOptimisticDoorCommand()
            servoState = restoredState
            lastError = "Controller rejected \(optimisticDoorCommand == .unlock ? "unlock" : "lock")."
            if origin == .proximity {
                endProximityUnlockBackgroundTask()
            }

            if restoredState == "locked" || restoredState == "unlocked" {
                publishWidgetState(restoredState)
            }
        }

        updatePairingState(from: "paired")

        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                _ = self?.readStateIfPermitted()
            }
        }
    }
}
