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
    typealias Command = DoorCommand
    typealias ControllerSettingOperation = DoorControllerSettingOperation

    enum DistanceUnit: String, CaseIterable, Identifiable {
        case meters
        case feet

        var id: String { rawValue }

        var title: String {
            switch self {
            case .meters:
                return "Meters"
            case .feet:
                return "Feet"
            }
        }

        var policyUnit: DoorDistanceUnit {
            switch self {
            case .meters:
                return .meters
            case .feet:
                return .feet
            }
        }
    }

    struct PairingInvite: Equatable {
        let lockName: String
        let inviterName: String?

        var title: String {
            inviterName.map { "\($0) invited you to \(lockName)." } ?? "You were invited to \(lockName)."
        }
    }

    enum CommandWriteIntent {
        case doorCommand(Command, Date?, DoorCommandOrigin)
        case autoLockTimeout(Int)
        case servoAngles(ServoAngles)
        case servoAnglesRefresh
        case lastUnlockRefresh
        case lockName(String)
        case lockNameRefresh
        case deviceDisplayName(String)
        case firmwareUpdate(URL)
        case linkAuthentication
        case pairingAdmin(String)
    }

    enum DoorCommandOrigin {
        case manual
        case proximity
    }

    enum LockZoneLocationRequest {
        case updateLockZoneAfterUnlock
        case setLockZoneFromSettings
        case proximityArmCheck(Date)
    }

    struct PendingFreshNonceDoorCommand {
        let command: Command
        let attempt: Int
        let previousServoState: String?
        let origin: DoorCommandOrigin
    }

    struct StartupTelemetryEntry: Identifiable, Equatable {
        let id = UUID()
        let elapsedMilliseconds: Int
        let event: String
        let details: String?

        var timeText: String {
            "\(elapsedMilliseconds) ms"
        }

        var title: String {
            switch event {
            case "controller_init":
                return "Controller object created"
            case "central_created":
                return "Bluetooth manager created"
            case "bluetooth_powered_on":
                return "Bluetooth powered on"
            case "powered_on_ready_skip_scan":
                return "Skipped redundant startup scan"
            case "powered_on_nonce_nudge":
                return "Nudged secure nonce immediately"
            case "scan_requested":
                return "Startup scan requested"
            case "known_peripheral_retrieved":
                return "Saved controller found"
            case "connected_peripheral_retrieved":
                return "Connected controller found"
            case "connect_start":
                return "Bluetooth connect started"
            case "connect_reused_connected":
                return "Existing connected link reused"
            case "connect_reused_connecting":
                return "Existing connecting link reused"
            case "restore_connected":
                return "Restored connected link"
            case "restore_connected_reused":
                return "Reused restored connection"
            case "restore_validation_succeeded":
                return "Restored connection validated"
            case "restore_validation_timeout":
                return "Restored connection required reconnect"
            case "restore_connecting":
                return "Restored connecting link"
            case "restore_connect_start":
                return "Restored controller reconnecting"
            case "service_discovery_start":
                return "Service discovery started"
            case "cached_service_available":
                return "Cached services available"
            case "services_discovered":
                return "Services discovered"
            case "characteristics_discovered":
                return "Characteristics discovered"
            case "gatt_ready":
                return "BLE control surface ready"
            case "state_notify_enabled":
                return "State notifications enabled"
            case "control_notify_enabled":
                return "Control notifications enabled"
            case "secure_nonce_requested":
                return "Secure nonce requested"
            case "secure_nonce_received":
                return "Secure nonce received"
            case "link_auth_probe_sent":
                return "Trusted link checked"
            case "door_command_dispatch_ready":
                return "Door command ready to dispatch"
            case "door_command_queued_for_nonce":
                return "Door command waiting for secure material"
            case "door_command_link_recovery":
                return "Recovered a stalled secure command"
            case "first_fast_payload_ready":
                return "Fast command prepared"
            case "peripheral_discovered":
                return "Controller advertisement seen"
            case "peripheral_connected":
                return "Controller connected"
            case "central_restored":
                return "Bluetooth restoration delivered"
            case "connection_state":
                return "Connection state changed"
            case "bluetooth_state":
                return "Bluetooth state changed"
            case "pairing_state":
                return "Pairing state changed"
            default:
                return event
                    .replacingOccurrences(of: "_", with: " ")
                    .capitalized
            }
        }
    }

    static let defaultAutoLockSeconds = DoorControllerPolicy.defaultAutoLockSeconds
    static let minimumAutoLockSeconds = DoorControllerPolicy.minimumAutoLockSeconds
    static let maximumAutoLockSeconds = DoorControllerPolicy.maximumAutoLockSeconds
    static let defaultServoLockAngle = DoorControllerPolicy.defaultServoLockAngle
    static let defaultServoUnlockAngle = DoorControllerPolicy.defaultServoUnlockAngle
    static let minimumServoAngle = DoorControllerPolicy.minimumServoAngle
    static let maximumServoAngle = DoorControllerPolicy.maximumServoAngle
    static let minimumServoAngleGap = DoorControllerPolicy.minimumServoAngleGap
    static let defaultUnlockHoldDurationSeconds = DoorControllerPolicy.defaultUnlockHoldDurationSeconds
    static let minimumUnlockHoldDurationSeconds = DoorControllerPolicy.minimumUnlockHoldDurationSeconds
    static let maximumUnlockHoldDurationSeconds = DoorControllerPolicy.maximumUnlockHoldDurationSeconds
    static let proximityUnlockArmDelaySeconds: TimeInterval = DoorControllerPolicy.proximityUnlockArmDelaySeconds
    static let proximityUnlockCooldownSeconds: TimeInterval = DoorControllerPolicy.proximityUnlockCooldownSeconds
    static let defaultLockZoneRadiusMeters = DoorControllerPolicy.defaultLockZoneRadiusMeters
    static let minimumLockZoneRadiusMeters = DoorControllerPolicy.minimumLockZoneRadiusMeters
    static let maximumLockZoneRadiusMeters = DoorControllerPolicy.maximumLockZoneRadiusMeters
    static let maximumLockZoneAccuracyMeters = DoorControllerPolicy.maximumLockZoneAccuracyMeters
    static let reliableProximityUnlockRSSIThreshold = DoorControllerPolicy.reliableProximityUnlockRSSIThreshold
    static let defaultProximityUnlockRSSIThreshold = reliableProximityUnlockRSSIThreshold
    static let minimumProximityUnlockRSSIThreshold = reliableProximityUnlockRSSIThreshold
    static let maximumProximityUnlockRSSIThreshold = -45
    static let fastKnownControllerRetryDelay: TimeInterval = 0.15
    static let activeConnectionRecoveryDelay: TimeInterval = 1.0
    static let controlNonceRequestMinimumInterval: TimeInterval = 0.22
    static let controlNonceRequestTimeout: TimeInterval = 0.45
    static let criticalStartupSnapshotMinimumFirmwareVersion = "0.1.25"
    static let acknowledgedDoorCommandSettleDelay: TimeInterval = 0.45
    static let liveActivityLockConfirmationSeconds: TimeInterval = 2.0
    static let liveActivityLockAnimationSettleSeconds: TimeInterval = 0.12
    static let liveActivityLockAnimationHalfSeconds: TimeInterval = 0.42
    static let liveActivityLockAnimationSwapSeconds: TimeInterval = 0.10
    static let liveActivityMinimumLockedHoldSeconds: TimeInterval = 0.75
    static let liveActivityLockedVisibleSeconds: TimeInterval = 1.35
    static let liveActivityStaleGraceSeconds: TimeInterval = 8.0
    static var liveActivityLockTransitionLeadSeconds: TimeInterval {
        liveActivityLockAnimationSettleSeconds + liveActivityLockAnimationHalfSeconds + liveActivityLockAnimationSwapSeconds
    }

    static let unlockAuthenticationKey = "RequireUnlockAuthentication"
    static let unlockHoldRequirementKey = "RequireHoldToUnlock"
    static let unlockHoldDurationKey = "UnlockHoldDurationSeconds"
    static let unlockNotificationsKey = "UnlockNotificationsEnabled"
    static let proximityUnlockArmedNotificationIdentifier = "DoorUnlockerProximityUnlockArmed"
    static let backgroundReliabilityWarningIdentifier = "DoorUnlockerBackgroundReliabilityWarning"
    static let backgroundReliabilityWarningLastScheduledAtKey = "DoorUnlockerBackgroundReliabilityWarningLastScheduledAt"
    static let proximityUnlockArmedNotificationLastSentAtKey = "DoorUnlockerProximityUnlockArmedNotificationLastSentAt"
    static let backgroundReliabilityWarningCooldown: TimeInterval = 12 * 60 * 60
    static let proximityUnlockArmedNotificationCooldown: TimeInterval = 60
    static let backgroundReliabilityWarningDelay: TimeInterval = 1
    static let forceQuitReliabilityWarningFireDelay: TimeInterval = 15
    static let forceQuitReliabilityWarningCancelDelay: TimeInterval = 12
    static let firmwareUpdateSuccessDisplayDuration: TimeInterval = 2.6
    static let proximityUnlockKey = "ProximityUnlockEnabled"
    static let proximityUnlockRSSIThresholdKey = "DoorUnlockerProximityUnlockRSSIThreshold"
    static let distanceUnitKey = "DoorUnlockerDistanceUnit"
    static let proximityUnlockArmedAtKey = "DoorUnlockerProximityUnlockArmedAt"
    static let maximumStoredProximityUnlockArmAge: TimeInterval = 12 * 60 * 60
    static let lockZoneLatitudeKey = "DoorUnlockerLockZoneLatitude"
    static let lockZoneLongitudeKey = "DoorUnlockerLockZoneLongitude"
    static let lockZoneRadiusKey = "DoorUnlockerLockZoneRadiusMeters"
    static let lockZoneUpdatedAtKey = "DoorUnlockerLockZoneUpdatedAt"
    static let lockZoneOutsideKey = "DoorUnlockerLockZoneOutside"
    static let lockZonePrecisionPurposeKey = "LockZonePrecision"
    static let hasRequestedAlwaysLocationKey = "DoorUnlockerHasRequestedAlwaysLocation"
    static let autoLockSecondsKey = "AutoLockSeconds"
    static let lastUnlockAtKey = "DoorUnlockerLastUnlockAt"
    static let lastUnlockDeviceIdentifierKey = "DoorUnlockerLastUnlockDeviceIdentifier"
    static let lastUnlockDeviceNameKey = "DoorUnlockerLastUnlockDeviceName"
    static let cachedFirmwareVersionKey = "DoorUnlockerCachedFirmwareVersion"
    static let deviceDisplayNameKey = "DoorUnlockerDeviceDisplayName"
    static let knownPeripheralIdentifierKey = "DoorUnlockerKnownPeripheralIdentifier"
    static let knownPeripheralIdentityVersionKey = "DoorUnlockerKnownPeripheralIdentityVersion"
    static let currentPeripheralIdentityVersion = "v4-control-characteristic"
    static let knownPairedControllerKey = "DoorUnlockerKnownPairedController"
    static let pendingBundledFirmwareUpdateVersionKey = "DoorUnlockerPendingBundledFirmwareUpdateVersion"
    static let pendingBundledFirmwareUpdateStartedAtKey = "DoorUnlockerPendingBundledFirmwareUpdateStartedAt"
    static let pendingBundledFirmwareUpdateMaximumAge: TimeInterval = 30 * 60
    static let centralRestorationIdentifier = "io.github.bt1142msstate.DoorUnlocker.central"
#if DEBUG
    static let debugFirmwareVerifiedNotificationPrefix = "io.github.bt1142msstate.DoorUnlocker.debugFirmwareVerified"
#endif
    static let widgetKind = "DoorUnlockerWidget"
}
