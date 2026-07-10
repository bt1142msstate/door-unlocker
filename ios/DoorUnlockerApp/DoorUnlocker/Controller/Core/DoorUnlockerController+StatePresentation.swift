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
    var isUnlocked: Bool {
        servoState == "unlocked" || servoState == "unlocking"
    }

    var isChangingState: Bool {
        servoState == "locking" || servoState == "unlocking"
    }

    var isBusy: Bool {
        isChangingState || isAuthenticatingUnlock
    }

    var isApplyingControllerSetting: Bool {
        pendingAutoLockTimeoutSeconds != nil ||
            queuedAutoLockTimeoutSeconds != nil ||
            pendingServoAngles != nil ||
            queuedServoAngles != nil ||
            sentServoAngles != nil ||
            pendingLockName != nil ||
            sentLockName != nil ||
            pendingDeviceDisplayName != nil ||
            sentDeviceDisplayName != nil ||
            remoteSettingApplyKind != nil
    }

    var controllerSettingApplyTitle: String {
        if let value = pendingLockName ?? sentLockName {
            return DoorControllerSettingFormatter.title(for: "lock_name", value: DoorControllerSettingFormatter.shortValue(value))
        }

        if let value = pendingDeviceDisplayName ?? sentDeviceDisplayName {
            return DoorControllerSettingFormatter.title(for: "device_name", value: DoorControllerSettingFormatter.shortValue(value))
        }

        if pendingServoAngles != nil || queuedServoAngles != nil || sentServoAngles != nil {
            let angles = pendingServoAngles ?? queuedServoAngles ?? sentServoAngles ?? ServoAngles(lockAngle: servoLockAngle, unlockAngle: servoUnlockAngle)
            return DoorControllerSettingFormatter.title(for: "servo_angles", value: DoorControllerSettingFormatter.servoAnglesValue(angles))
        }

        if pendingAutoLockTimeoutSeconds != nil || queuedAutoLockTimeoutSeconds != nil {
            let seconds = pendingAutoLockTimeoutSeconds ?? queuedAutoLockTimeoutSeconds ?? autoLockSeconds
            return DoorControllerSettingFormatter.title(for: "timeout", value: "\(seconds)s")
        }

        if let remoteSettingApplyKind {
            return DoorControllerSettingFormatter.title(
                for: remoteSettingApplyKind,
                value: DoorControllerSettingFormatter.displayValue(for: remoteSettingApplyKind, rawValue: remoteSettingApplyValue)
            )
        }

        return "Applying setting"
    }

    static func formattedDistance(_ meters: Double, unit: DistanceUnit) -> String {
        DoorControllerPolicy.formattedDistance(meters, unit: unit.policyUnit)
    }

    func formattedDistance(_ meters: Double) -> String {
        Self.formattedDistance(meters, unit: distanceUnit)
    }

    var hasKnownLockState: Bool {
        servoState == "locked" || servoState == "unlocked" || servoState == "locking" || servoState == "unlocking"
    }

    var lastUnlockTitle: String {
        guard let lastUnlockAt else { return "No unlock recorded" }
        return lastUnlockAt.formatted(date: .abbreviated, time: .shortened)
    }

    var lastUnlockRelativeTitle: String? {
        guard let lastUnlockAt else { return nil }
        return lastUnlockAt.formatted(.relative(presentation: .named))
    }

    var lastUnlockDeviceTitle: String? {
        guard lastUnlockAt != nil, !lastUnlockDeviceName.isEmpty else { return nil }
        return lastUnlockDeviceName
    }

    var stateTitle: String {
        switch servoState {
        case "locked":
            return "Locked"
        case "unlocked":
            return "Unlocked"
        case "locking":
            return "Locking"
        case "unlocking":
            return "Unlocking"
        case "rejected":
            return "Rejected"
        case "unpaired":
            return "Pairing Locked"
        case "pairing_locked":
            return "Pairing Locked"
        case "pairing_enabled":
            return "Pairing Enabled"
        case "pairing_pending":
            return "Pairing Pending"
        case "paired":
            return "Paired"
        case "timeout_set":
            return "Auto-lock Updated"
        default:
            if canAcceptDoorCommand {
                return "Ready"
            }
            return isReady ? "Ready" : connectionState
        }
    }

    var autoLockRange: ClosedRange<Int> {
        DoorControllerPolicy.autoLockRange
    }

    var servoAngleRange: ClosedRange<Int> {
        DoorControllerPolicy.servoAngleRange
    }

    var servoAnglesAreAtDefaults: Bool {
        servoLockAngle == Self.defaultServoLockAngle && servoUnlockAngle == Self.defaultServoUnlockAngle
    }

    var unlockHoldDurationRange: ClosedRange<Double> {
        DoorControllerPolicy.unlockHoldDurationRange
    }

    var lockZoneRadiusRange: ClosedRange<Double> {
        DoorControllerPolicy.lockZoneRadiusRange
    }

    var proximityUnlockRSSIThresholdRange: ClosedRange<Int> {
        DoorControllerPolicy.proximityUnlockRSSIThresholdRange
    }

    var proximityUnlockRSSIGateEnabled: Bool {
        proximityUnlockRSSIThreshold != nil
    }

    var proximityUnlockRSSISliderValue: Int {
        proximityUnlockRSSIThreshold ?? Self.defaultProximityUnlockRSSIThreshold
    }

    var proximityUnlockRSSIThresholdTitle: String {
        guard let proximityUnlockRSSIThreshold else { return "Auto \(Self.reliableProximityUnlockRSSIThreshold) dBm" }
        return "\(proximityUnlockRSSIThreshold) dBm"
    }

    var currentBluetoothSignalTitle: String {
        guard let lockZoneBluetoothRSSI else { return "Reading signal" }
        return "Current \(lockZoneBluetoothRSSI) dBm"
    }

    var isBluetoothSignalStrongForGuidance: Bool {
        guard let lockZoneBluetoothRSSI else { return false }
        return lockZoneBluetoothRSSI >= effectiveProximityUnlockRSSIThreshold
    }

    var lockZoneUpdatedTitle: String? {
        guard let lockZoneUpdatedAt else { return nil }
        return lockZoneUpdatedAt.formatted(.relative(presentation: .named))
    }

    var lockZoneLocationSummary: String {
        guard lockZoneCenter != nil else { return "Unlock once to set the lock zone." }
        if locationManager.authorizationStatus == .authorizedWhenInUse || locationManager.authorizationStatus == .authorizedAlways,
           locationManager.accuracyAuthorization == .reducedAccuracy {
            return "Precise Location is off for Door Unlocker."
        }

        guard lockZoneUserLocation != nil else {
            switch locationManager.authorizationStatus {
            case .denied, .restricted:
                return "Location is off for Door Unlocker."
            case .notDetermined:
                return "Location permission has not been granted yet."
            default:
                return "Waiting for your location."
            }
        }

        let zoneTitle = isKnownOutsideLockZone ? "You left the zone" : "You are inside the zone"
        let distanceTitle = lockZoneDistanceMeters.map { " - \(formattedDistance($0)) from lock" } ?? ""
        let accuracyTitle = lockZoneUserAccuracyMeters.map { " - +/-\(formattedDistance($0))" } ?? ""
        if let accuracy = lockZoneUserAccuracyMeters,
           accuracy > Self.maximumLockZoneAccuracyMeters {
            return "Location accuracy is low\(accuracyTitle)"
        }

        return "\(zoneTitle)\(distanceTitle)\(accuracyTitle)"
    }

    var lockZoneLocationSystemImage: String {
        guard lockZoneCenter != nil else { return "location.slash.fill" }
        guard lockZoneUserLocation != nil else { return "location.circle.fill" }
        return isKnownOutsideLockZone ? "figure.walk.motion" : "location.fill"
    }

    var proximityUnlockDetail: String {
        guard proximityUnlockEnabled else { return "Off" }
        guard lockZoneCenter != nil else { return "Set a lock zone before proximity unlock can arm." }

        if proximityUnlockArmedAt != nil {
            let threshold = effectiveProximityUnlockRSSIThreshold
            guard let lockZoneBluetoothRSSI else {
                return "Armed. Waiting for a reliable Bluetooth signal before unlock."
            }

            if lockZoneBluetoothRSSI < threshold {
                return "Armed. Waiting for a stable Bluetooth signal before unlock."
            }

            return "Armed. It will unlock when your phone reconnects near the lock."
        }

        if proximityUnlockCandidateStartedAt != nil {
            return "Checking that you left the zone before arming."
        }

        if isKnownOutsideLockZone {
            return isReady ? "Left zone. It will arm after Bluetooth disconnects." : "Left zone. It will unlock on next reconnect."
        }

        return isReady ? "Inside zone. Proximity unlock is not armed." : "Waiting for controller."
    }

    var autoLockCountdownText: String? {
        guard isUnlocked, let autoLockRemainingSeconds else { return nil }
        guard autoLockRemainingSeconds > 0 else { return "Auto-locking now" }
        return "Auto-locks in \(autoLockRemainingSeconds)s"
    }
}
