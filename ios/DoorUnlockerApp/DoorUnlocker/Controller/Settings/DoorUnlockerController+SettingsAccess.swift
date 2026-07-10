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
    func unlockSettings() {
        guard !areSettingsUnlocked, !isAuthenticatingSettings else { return }

        Task { [weak self] in
            await self?.authenticateSettingsAccess()
        }
    }

    func lockSettings() {
        areSettingsUnlocked = false
    }

#if DEBUG
    func handleDebugLaunchArgumentsIfNeeded() {
        guard !didHandleDebugLaunchFirmwareUpdateArgument else { return }
        guard ProcessInfo.processInfo.arguments.contains("--debug-install-bundled-firmware") else { return }

        didHandleDebugLaunchFirmwareUpdateArgument = true
        debugExpectedFirmwareVersion = Self.debugLaunchArgumentValue(named: "--debug-expected-firmware")
        if let debugExpectedFirmwareVersion {
            recordStartupTelemetry("debug_expected_firmware", details: debugExpectedFirmwareVersion, once: false)
        }
        recordStartupTelemetry("debug_firmware_argument_received")
        startBundledFirmwareUpdateForTesting()
    }

    func startBundledFirmwareUpdateForTesting() {
        recordStartupTelemetry("debug_firmware_update_start", once: false)
        areSettingsUnlocked = true
        startBundledFirmwareUpdate()
    }

    static func debugLaunchArgumentValue(named name: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        for (index, argument) in arguments.enumerated() {
            if argument == name, index + 1 < arguments.count {
                return arguments[index + 1]
            }
            let prefix = "\(name)="
            if argument.hasPrefix(prefix) {
                return String(argument.dropFirst(prefix.count))
            }
        }
        return nil
    }

    static func debugFirmwareVerifiedNotificationName(for version: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let suffix = version.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? String(scalar) : "_"
        }.joined()
        return "\(debugFirmwareVerifiedNotificationPrefix).\(suffix)"
    }

    func handleDebugFirmwareVersionVerification(_ version: String) {
        guard debugFirmwareAwaitingPostDfuVerification,
              !debugFirmwareVerifiedNotificationPosted,
              let expectedVersion = debugExpectedFirmwareVersion else {
            return
        }

        guard version == expectedVersion else {
            recordStartupTelemetry(
                "debug_firmware_wireless_verify_mismatch",
                details: "expected=\(expectedVersion) actual=\(version)",
                once: false
            )
            return
        }

        debugFirmwareVerifiedNotificationPosted = true
        debugFirmwareAwaitingPostDfuVerification = false
        let notificationName = Self.debugFirmwareVerifiedNotificationName(for: expectedVersion)
        recordStartupTelemetry("debug_firmware_wireless_verified", details: expectedVersion, once: false)
        print("DUFirmwareVerified version=\(expectedVersion) notification=\(notificationName)")
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(notificationName as CFString),
            nil,
            nil,
            true
        )
    }
#endif
}
