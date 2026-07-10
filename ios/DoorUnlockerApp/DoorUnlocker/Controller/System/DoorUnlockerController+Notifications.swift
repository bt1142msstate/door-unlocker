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
    func requestUnlockNotificationAuthorization() {
        unlockNotificationStatus = "Requesting"
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            Task { @MainActor in
                guard let self else { return }
                self.unlockNotificationsEnabled = granted
                UserDefaults.standard.set(granted, forKey: Self.unlockNotificationsKey)
                self.unlockNotificationStatus = granted ? "On" : "Permission needed"
                if !granted {
                    self.lastError = "Enable Door Unlocker notifications in iPhone Settings."
                }
                self.refreshNotificationSettings()
            }
        }
    }

    func requestBackgroundReliabilityNotificationAuthorizationIfNeeded() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }

            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] _, _ in
                Task { @MainActor in
                    self?.refreshNotificationSettings()
                }
            }
        }
    }

    func notifyProximityUnlockArmedIfNeeded() {
        let now = Date()
        let lastSentTimestamp = UserDefaults.standard.double(forKey: Self.proximityUnlockArmedNotificationLastSentAtKey)
        guard lastSentTimestamp == 0 ||
                now.timeIntervalSince1970 - lastSentTimestamp >= Self.proximityUnlockArmedNotificationCooldown else {
            return
        }

        let lockTitle = lockName
        let notificationIdentifier = Self.proximityUnlockArmedNotificationIdentifier
        let lastSentKey = Self.proximityUnlockArmedNotificationLastSentAtKey

        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                let content = UNMutableNotificationContent()
                content.title = "\(lockTitle) proximity unlock armed"
                content.body = "Your phone left the lock zone. It will unlock when Bluetooth reconnects near the controller."
                content.sound = .default
                content.threadIdentifier = "DoorUnlocker"

                let request = UNNotificationRequest(
                    identifier: notificationIdentifier,
                    content: content,
                    trigger: nil
                )

                UNUserNotificationCenter.current().removePendingNotificationRequests(
                    withIdentifiers: [notificationIdentifier]
                )
                UNUserNotificationCenter.current().add(request) { error in
                    guard error == nil else { return }
                    UserDefaults.standard.set(now.timeIntervalSince1970, forKey: lastSentKey)
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

    @objc nonisolated func applicationWillTerminate() {
        Task { @MainActor in
            guard forceQuitReliabilityWarningTask != nil else { return }
            scheduleBackgroundReliabilityWarningIfNeeded(delay: 1, bypassCooldown: true)
        }
    }

    func applyNotificationSettings(_ settings: UNNotificationSettings) {
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            unlockNotificationStatus = unlockNotificationsEnabled ? "On" : "Off"
        case .denied:
            unlockNotificationsEnabled = false
            UserDefaults.standard.set(false, forKey: Self.unlockNotificationsKey)
            unlockNotificationStatus = "Permission needed"
        case .notDetermined:
            unlockNotificationStatus = unlockNotificationsEnabled ? "Permission needed" : "Off"
        @unknown default:
            unlockNotificationStatus = "Unknown"
        }
    }

    func notifyIfNeeded(
        for state: String,
        previousSnapshot: DoorStatusStore.Snapshot,
        deadline: Date?
    ) {
        guard state == "unlocked",
              previousSnapshot.state != "unlocked",
              unlockNotificationsEnabled,
              UIApplication.shared.applicationState != .active else {
            return
        }

        let notificationLockName = lockName
        let notificationIdentifier = doorUnlockerUnlockNotificationIdentifier

        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized ||
                    settings.authorizationStatus == .provisional ||
                    settings.authorizationStatus == .ephemeral else {
                return
            }

            let content = UNMutableNotificationContent()
            content.title = "\(notificationLockName) unlocked"
            if let deadline, deadline > .now {
                let remainingSeconds = max(0, Int(ceil(deadline.timeIntervalSinceNow)))
                content.body = "Auto-locks in \(remainingSeconds) seconds."
            } else {
                content.body = "\(notificationLockName) is unlocked."
            }
            content.sound = .default
            content.threadIdentifier = "DoorUnlocker"

            let request = UNNotificationRequest(
                identifier: notificationIdentifier,
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request)
        }
    }

    func predictedAutoLockDeadline(
        for state: String,
        updatedAt: Date,
        resetAutoLockDeadline: Bool,
        controllerRemainingSeconds: Int?
    ) -> Date? {
        switch state {
        case "unlocking", "unlocked":
            if let controllerRemainingSeconds {
                return updatedAt.addingTimeInterval(TimeInterval(max(0, controllerRemainingSeconds)))
            }

            let snapshot = DoorStatusStore.load()
            if !resetAutoLockDeadline,
               snapshot.isUnlocked,
               let existingDeadline = snapshot.autoLockDeadline,
               existingDeadline > updatedAt,
               !(snapshot.state == "unlocking" && state == "unlocked") {
                return existingDeadline
            }

            let movementGraceSeconds = state == "unlocking" ? 2 : 0
            return updatedAt.addingTimeInterval(TimeInterval(autoLockSeconds + movementGraceSeconds))
        default:
            return nil
        }
    }

    func predictedAutoLockStartedAt(
        for state: String,
        updatedAt: Date,
        resetAutoLockDeadline: Bool,
        controllerRemainingSeconds: Int?,
        deadline: Date?
    ) -> Date? {
        guard (state == "unlocking" || state == "unlocked"), let deadline else {
            return nil
        }

        if controllerRemainingSeconds != nil {
            return deadline.addingTimeInterval(-TimeInterval(max(1, autoLockSeconds)))
        }

        let snapshot = DoorStatusStore.load()
        if !resetAutoLockDeadline,
           snapshot.isUnlocked,
           let existingDeadline = snapshot.autoLockDeadline,
           abs(existingDeadline.timeIntervalSince(deadline)) < 1.5,
           let existingStartedAt = snapshot.autoLockStartedAt {
            return existingStartedAt
        }

        return updatedAt
    }
}
