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
    func refreshNotificationSettings() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            Task { @MainActor in
                self?.applyNotificationSettings(settings)
            }
        }
    }

    func scheduleBackgroundReliabilityWarningIfNeeded(
        delay: TimeInterval? = nil,
        bypassCooldown: Bool = false
    ) {
        guard proximityUnlockEnabled,
              lockZoneCenter != nil else {
            cancelBackgroundReliabilityWarning()
            return
        }

        let now = Date()
        if !bypassCooldown {
            let lastScheduledTimestamp = UserDefaults.standard.double(forKey: Self.backgroundReliabilityWarningLastScheduledAtKey)
            if lastScheduledTimestamp > 0,
               now.timeIntervalSince1970 - lastScheduledTimestamp < Self.backgroundReliabilityWarningCooldown {
                return
            }
        }

        let lockTitle = lockName
        let triggerDelay = max(1, delay ?? Self.backgroundReliabilityWarningDelay)
        let warningIdentifier = Self.backgroundReliabilityWarningIdentifier
        let lastScheduledKey = Self.backgroundReliabilityWarningLastScheduledAtKey

        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                let content = UNMutableNotificationContent()
                content.title = "Keep \(lockTitle) ready"
                content.body = "Proximity unlock works best when Door Unlocker stays running in the background. If you force-quit it, automatic unlock may not run."
                content.sound = .default
                content.threadIdentifier = "DoorUnlocker"

                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: triggerDelay, repeats: false)
                let request = UNNotificationRequest(
                    identifier: warningIdentifier,
                    content: content,
                    trigger: trigger
                )

                UNUserNotificationCenter.current().removePendingNotificationRequests(
                    withIdentifiers: [warningIdentifier]
                )
                UNUserNotificationCenter.current().add(request) { error in
                    guard error == nil else { return }
                    UserDefaults.standard.set(now.timeIntervalSince1970, forKey: lastScheduledKey)
                }
            case .notDetermined:
                Task { @MainActor in
                    self?.requestBackgroundReliabilityNotificationAuthorizationIfNeeded()
                }
            default:
                break
            }
        }
    }

    func cancelBackgroundReliabilityWarning() {
        let warningIdentifier = Self.backgroundReliabilityWarningIdentifier
        let lastScheduledKey = Self.backgroundReliabilityWarningLastScheduledAtKey

        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: [warningIdentifier]
        )
        UserDefaults.standard.removeObject(forKey: lastScheduledKey)
    }

    func prepareForceQuitReliabilityWarningIfNeeded() {
        guard proximityUnlockEnabled,
              lockZoneCenter != nil else {
            cancelForceQuitReliabilityWarning()
            return
        }

        forceQuitReliabilityWarningTask?.cancel()
        beginForceQuitReliabilityWarningBackgroundTask()
        scheduleBackgroundReliabilityWarningIfNeeded(
            delay: Self.forceQuitReliabilityWarningFireDelay,
            bypassCooldown: true
        )

        let cancelDelay = UInt64(Self.forceQuitReliabilityWarningCancelDelay * 1_000_000_000)
        forceQuitReliabilityWarningTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: cancelDelay)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard let self else { return }
                self.cancelBackgroundReliabilityWarning()
                self.forceQuitReliabilityWarningTask = nil
                self.endForceQuitReliabilityWarningBackgroundTask()
            }
        }
    }

    func cancelForceQuitReliabilityWarning() {
        forceQuitReliabilityWarningTask?.cancel()
        forceQuitReliabilityWarningTask = nil
        cancelBackgroundReliabilityWarning()
        endForceQuitReliabilityWarningBackgroundTask()
    }
}
