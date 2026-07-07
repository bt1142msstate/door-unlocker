import CoreBluetooth
import CoreLocation
import Foundation
import ActivityKit
import LocalAuthentication
import UIKit
import UserNotifications
import WidgetKit

@MainActor
final class DoorUnlockerController: NSObject, ObservableObject {
    enum Command: String {
        case unlock = "UNLOCK"
        case lock = "LOCK"

        var commandText: String {
            rawValue
        }
    }

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
    }

    private enum CommandWriteIntent {
        case doorCommand(Command, Date?, DoorCommandOrigin)
        case autoLockTimeout(Int)
        case servoAngles(ServoAngles)
        case servoAnglesRefresh
        case lastUnlockRefresh
        case lockName(String)
        case lockNameRefresh
        case deviceDisplayName(String)
    }

    private enum DoorCommandOrigin {
        case manual
        case proximity
    }

    private struct ServoAngles: Equatable {
        let lockAngle: Int
        let unlockAngle: Int
    }

    private enum LockZoneLocationRequest {
        case updateLockZoneAfterUnlock
        case setLockZoneFromSettings
        case proximityArmCheck(Date)
    }

    private struct LastUnlockRecord {
        let unlockedAt: Date?
        let deviceIdentifier: String?
        let deviceName: String?
    }

    private struct PendingFreshNonceDoorCommand {
        let command: Command
        let attempt: Int
        let previousServoState: String?
        let origin: DoorCommandOrigin
    }

    struct ConnectedControllerDevice: Identifiable, Equatable {
        let slot: Int
        let name: String

        var id: Int { slot }

        var displayName: String {
            name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Connected Device \(slot)" : name
        }
    }

    static let defaultAutoLockSeconds = 30
    static let minimumAutoLockSeconds = 5
    static let maximumAutoLockSeconds = 120
    static let defaultServoLockAngle = 20
    static let defaultServoUnlockAngle = 95
    static let minimumServoAngle = 10
    static let maximumServoAngle = 170
    static let minimumServoAngleGap = 10
    static let defaultUnlockHoldDurationSeconds = 1.0
    static let minimumUnlockHoldDurationSeconds = 0.5
    static let maximumUnlockHoldDurationSeconds = 3.0
    static let proximityUnlockArmDelaySeconds: TimeInterval = 8.0
    static let proximityUnlockCooldownSeconds: TimeInterval = 30.0
    static let defaultLockZoneRadiusMeters = 25.0
    static let minimumLockZoneRadiusMeters = 5.0
    static let maximumLockZoneRadiusMeters = 150.0
    static let maximumLockZoneAccuracyMeters = 75.0
    static let reliableProximityUnlockRSSIThreshold = -82
    static let defaultProximityUnlockRSSIThreshold = reliableProximityUnlockRSSIThreshold
    static let minimumProximityUnlockRSSIThreshold = reliableProximityUnlockRSSIThreshold
    static let maximumProximityUnlockRSSIThreshold = -45
    private static let liveActivityLockConfirmationSeconds: TimeInterval = 2.0
    private static let liveActivityLockAnimationSettleSeconds: TimeInterval = 0.12
    private static let liveActivityLockAnimationHalfSeconds: TimeInterval = 0.42
    private static let liveActivityLockAnimationSwapSeconds: TimeInterval = 0.10
    private static let liveActivityMinimumLockedHoldSeconds: TimeInterval = 0.75
    private static let liveActivityLockedVisibleSeconds: TimeInterval = 1.35
    private static let liveActivityStaleGraceSeconds: TimeInterval = 8.0
    private static var liveActivityLockTransitionLeadSeconds: TimeInterval {
        liveActivityLockAnimationSettleSeconds + liveActivityLockAnimationHalfSeconds + liveActivityLockAnimationSwapSeconds
    }

    @Published private(set) var bluetoothState = "Starting"
    @Published private(set) var connectionState = "Disconnected"
    @Published private(set) var deviceName = "DoorUnlocker-XIAO-v4"
    @Published private(set) var connectedDeviceCount = 0
    @Published private(set) var maximumConnectedDeviceCount = 4
    @Published private(set) var connectedDevices: [ConnectedControllerDevice] = []
    @Published private(set) var servoState = "unknown"
    @Published private(set) var pairingState = "Unknown"
    @Published private(set) var pairingApprovalCode: String?
    @Published private(set) var isAuthenticatingUnlock = false
    @Published private(set) var isAuthenticatingSettings = false
    @Published private(set) var areSettingsUnlocked = false
    @Published private(set) var autoLockSeconds = DoorUnlockerController.storedAutoLockSeconds()
    @Published private(set) var autoLockStatus = "Ready to set"
    @Published private(set) var autoLockRemainingSeconds: Int?
    @Published private(set) var servoLockAngle = DoorUnlockerController.defaultServoLockAngle
    @Published private(set) var servoUnlockAngle = DoorUnlockerController.defaultServoUnlockAngle
    @Published private(set) var servoAnglesStatus = "Controller set"
    @Published private(set) var lastUnlockAt = DoorUnlockerController.storedLastUnlockAt()
    @Published private(set) var lastUnlockDeviceIdentifier = DoorUnlockerController.storedLastUnlockDeviceIdentifier()
    @Published private(set) var lastUnlockDeviceName = DoorUnlockerController.storedLastUnlockDeviceName()
    @Published private(set) var lockName = DoorStatusStore.loadLockName()
    @Published private(set) var deviceDisplayName = DoorUnlockerController.storedDeviceDisplayName()
    @Published private(set) var lockNameStatus = "Shown in app and widget"
    @Published private(set) var deviceDisplayNameStatus = "Ready to sync"
    @Published private(set) var requiresUnlockAuthentication = UserDefaults.standard.bool(forKey: DoorUnlockerController.unlockAuthenticationKey)
    @Published private(set) var requiresHoldToUnlock = UserDefaults.standard.bool(forKey: DoorUnlockerController.unlockHoldRequirementKey)
    @Published private(set) var unlockHoldDurationSeconds = DoorUnlockerController.storedUnlockHoldDurationSeconds()
    @Published private(set) var unlockNotificationsEnabled = UserDefaults.standard.bool(forKey: DoorUnlockerController.unlockNotificationsKey)
    @Published private(set) var unlockNotificationStatus = "Checking"
    @Published private(set) var proximityUnlockEnabled = DoorUnlockerController.storedProximityUnlockEnabled()
    @Published private(set) var proximityUnlockRSSIThreshold = DoorUnlockerController.storedProximityUnlockRSSIThreshold()
    @Published private(set) var distanceUnit = DoorUnlockerController.storedDistanceUnit()
    @Published private(set) var proximityUnlockStatus = DoorUnlockerController.storedProximityUnlockEnabled() ? "Monitoring" : "Off"
    @Published private(set) var lockZoneCenter = DoorUnlockerController.storedLockZoneCenter()
    @Published private(set) var lockZoneRadiusMeters = DoorUnlockerController.storedLockZoneRadiusMeters()
    @Published private(set) var lockZoneUpdatedAt = DoorUnlockerController.storedLockZoneUpdatedAt()
    @Published private(set) var lockZoneStatus = DoorUnlockerController.storedLockZoneCenter() == nil ? "Unlock once to set" : "Ready"
    @Published private(set) var lockZoneUserLocation: CLLocationCoordinate2D?
    @Published private(set) var lockZoneUserAccuracyMeters: Double?
    @Published private(set) var lockZoneDistanceMeters: Double?
    @Published private(set) var lockZoneHeadingDegrees: Double?
    @Published private(set) var lockZoneHeadingAccuracyDegrees: Double?
    @Published private(set) var lockZoneCourseDegrees: Double?
    @Published private(set) var lockZoneCourseAccuracyDegrees: Double?
    @Published private(set) var lockZoneSpeedMetersPerSecond: Double?
    @Published private(set) var lockZoneBluetoothRSSI: Int?
    @Published private(set) var remoteSettingApplyKind: String?
    @Published private(set) var remoteSettingApplyValue: String?
    @Published var lastError: String?

    private static let unlockAuthenticationKey = "RequireUnlockAuthentication"
    private static let unlockHoldRequirementKey = "RequireHoldToUnlock"
    private static let unlockHoldDurationKey = "UnlockHoldDurationSeconds"
    private static let unlockNotificationsKey = "UnlockNotificationsEnabled"
    private static let unlockNotificationIdentifier = "DoorUnlockerUnlocked"
    private static let proximityUnlockArmedNotificationIdentifier = "DoorUnlockerProximityUnlockArmed"
    private static let backgroundReliabilityWarningIdentifier = "DoorUnlockerBackgroundReliabilityWarning"
    private static let backgroundReliabilityWarningLastScheduledAtKey = "DoorUnlockerBackgroundReliabilityWarningLastScheduledAt"
    private static let proximityUnlockArmedNotificationLastSentAtKey = "DoorUnlockerProximityUnlockArmedNotificationLastSentAt"
    private static let backgroundReliabilityWarningCooldown: TimeInterval = 12 * 60 * 60
    private static let proximityUnlockArmedNotificationCooldown: TimeInterval = 60
    private static let backgroundReliabilityWarningDelay: TimeInterval = 1
    private static let forceQuitReliabilityWarningFireDelay: TimeInterval = 15
    private static let forceQuitReliabilityWarningCancelDelay: TimeInterval = 12
    private static let proximityUnlockKey = "ProximityUnlockEnabled"
    private static let proximityUnlockRSSIThresholdKey = "DoorUnlockerProximityUnlockRSSIThreshold"
    private static let distanceUnitKey = "DoorUnlockerDistanceUnit"
    private static let legacyProximityUnlockArmedAtKey = "ProximityUnlockArmedAt"
    private static let proximityUnlockArmedAtKey = "DoorUnlockerProximityUnlockArmedAt"
    private static let maximumStoredProximityUnlockArmAge: TimeInterval = 12 * 60 * 60
    private static let lockZoneLatitudeKey = "DoorUnlockerLockZoneLatitude"
    private static let lockZoneLongitudeKey = "DoorUnlockerLockZoneLongitude"
    private static let lockZoneRadiusKey = "DoorUnlockerLockZoneRadiusMeters"
    private static let lockZoneUpdatedAtKey = "DoorUnlockerLockZoneUpdatedAt"
    private static let lockZoneOutsideKey = "DoorUnlockerLockZoneOutside"
    private static let lockZoneRegionIdentifier = "DoorUnlockerLockZone"
    private static let lockZonePrecisionPurposeKey = "LockZonePrecision"
    private static let hasRequestedAlwaysLocationKey = "DoorUnlockerHasRequestedAlwaysLocation"
    private static let autoLockSecondsKey = "AutoLockSeconds"
    private static let lastUnlockAtKey = "DoorUnlockerLastUnlockAt"
    private static let lastUnlockDeviceIdentifierKey = "DoorUnlockerLastUnlockDeviceIdentifier"
    private static let lastUnlockDeviceNameKey = "DoorUnlockerLastUnlockDeviceName"
    private static let deviceDisplayNameKey = "DoorUnlockerDeviceDisplayName"
    private static let knownPeripheralIdentifierKey = "DoorUnlockerKnownPeripheralIdentifier"
    private static let knownPeripheralIdentityVersionKey = "DoorUnlockerKnownPeripheralIdentityVersion"
    private static let currentPeripheralIdentityVersion = "v4-control-characteristic"
    private static let knownPairedControllerKey = "DoorUnlockerKnownPairedController"
    private static let centralRestorationIdentifier = "com.brandontemple.DoorUnlocker.central"
    private static let knownPeripheralFreshScanFallbackDelay: TimeInterval = 0.6
    private static let maximumDeviceDisplayNameLength = 24
    private static let widgetKind = "DoorUnlockerWidget"
    private let serviceUUID = CBUUID(string: "7A5A2000-2B8D-4C3E-94E7-0B3C0DDAAF10")
    private let commandUUID = CBUUID(string: "7A5A2001-2B8D-4C3E-94E7-0B3C0DDAAF10")
    private let stateUUID = CBUUID(string: "7A5A2002-2B8D-4C3E-94E7-0B3C0DDAAF10")
    private let pairingUUID = CBUUID(string: "7A5A2003-2B8D-4C3E-94E7-0B3C0DDAAF10")
    private let controlUUID = CBUUID(string: "7A5A2004-2B8D-4C3E-94E7-0B3C0DDAAF10")

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var commandCharacteristic: CBCharacteristic?
    private var stateCharacteristic: CBCharacteristic?
    private var pairingCharacteristic: CBCharacteristic?
    private var controlCharacteristic: CBCharacteristic?
    private var reconnectTimer: Timer?
    private var pendingSystemCommand: DoorSystemCommand?
    private var pendingCommandWriteIntents: [CommandWriteIntent] = []
    private var optimisticDoorCommand: Command?
    private var optimisticDoorCommandOrigin: DoorCommandOrigin?
    private var optimisticDoorCommandSentAt: Date?
    private var optimisticDoorCommandAttempt = 0
    private var optimisticDoorPreviousServoState: String?
    private var doorCommandRecoveryTask: Task<Void, Never>?
    private var pendingFreshNonceDoorCommand: PendingFreshNonceDoorCommand?
    private var fastCommandNonce: Data?
    private var preparedFastDoorCommandPayloads: [Command: DoorCommandAuthenticator.SignedFastCommandPayload] = [:]
    private var preparedFastDoorCommandTask: Task<Void, Never>?
    private var preparedFastDoorCommandGeneration = 0
    private var pendingAutoLockTimeoutSeconds: Int?
    private var queuedAutoLockTimeoutSeconds: Int?
    private var pendingServoAngles: ServoAngles?
    private var queuedServoAngles: ServoAngles?
    private var autoLockApplyTask: Task<Void, Never>?
    private var servoAnglesApplyTask: Task<Void, Never>?
    private var autoLockPredictionTask: Task<Void, Never>?
    private var lockNameSyncTask: Task<Void, Never>?
    private var deviceDisplayNameSyncTask: Task<Void, Never>?
    private var pendingLockName: String?
    private var sentLockName: String?
    private var lastSyncedLockName: String?
    private var hasRequestedControllerLockName = false
    private var sentServoAngles: ServoAngles?
    private var hasRequestedControllerServoAngles = false
    private var hasRequestedControllerLastUnlock = false
    private var pendingDeviceDisplayName: String?
    private var sentDeviceDisplayName: String?
    private var lastSyncedDeviceDisplayName: String?
    private var knownPairingFallbackTask: Task<Void, Never>?
    private var liveActivity: Activity<DoorUnlockerActivityAttributes>?
    private var liveActivityCompletionTask: Task<Void, Never>?
    private var isCompletingLiveActivity = false
    private var liveActivityBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var widgetReloadTask: Task<Void, Never>?
    private var widgetReloadBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var widgetReloadGeneration = 0
    private var proximityUnlockBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var forceQuitReliabilityWarningTask: Task<Void, Never>?
    private var forceQuitReliabilityWarningBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var proximityUnlockCandidateStartedAt: Date?
    private var proximityUnlockArmTask: Task<Void, Never>?
    private var proximityUnlockArmedAt = DoorUnlockerController.storedProximityUnlockArmedAt()
    private var lastProximityUnlockAt: Date?
    private var hasKnownPairedController = UserDefaults.standard.bool(forKey: DoorUnlockerController.knownPairedControllerKey)
    private var remoteSettingApplyTask: Task<Void, Never>?
    private var rssiReadTask: Task<Void, Never>?
    private var secureLinkWatchdogTask: Task<Void, Never>?
    private let locationManager = CLLocationManager()
    private var pendingLocationRequests: [LockZoneLocationRequest] = []
    private var isKnownOutsideLockZone = UserDefaults.standard.bool(forKey: DoorUnlockerController.lockZoneOutsideKey)
    private var latestLockZoneLocation: CLLocation?
    private var isRequestingTemporaryFullAccuracy = false
    private var isLockZoneLocationUpdating = false
    private var isSignificantLocationMonitoringActive = false

    var isConnectedToController: Bool {
        pairingCharacteristic != nil && peripheral?.state == .connected
    }

    var isPaired: Bool {
        pairingState == "Paired"
    }

    var isReady: Bool {
        commandCharacteristic != nil && peripheral?.state == .connected && isPaired
    }

    var isDoorCommandReady: Bool {
        isReady && !preparedFastDoorCommandPayloads.isEmpty
    }

    var secureLinkActionTitle: String {
        guard isReady, !isDoorCommandReady else {
            return isUnlocked ? "Tap to lock" : "Tap to unlock"
        }

        if let lockZoneBluetoothRSSI,
           lockZoneBluetoothRSSI < Self.reliableProximityUnlockRSSIThreshold {
            return "Move closer"
        }

        if lockZoneBluetoothRSSI == nil {
            return "Checking signal..."
        }

        if controlCharacteristic == nil {
            return "Opening secure control..."
        }

        if fastCommandNonce == nil {
            return "Preparing control..."
        }

        return "Preparing control..."
    }

    var secureLinkStatusTitle: String {
        guard isReady, !isDoorCommandReady else { return "Controller is ready." }

        if let lockZoneBluetoothRSSI,
           lockZoneBluetoothRSSI < Self.reliableProximityUnlockRSSIThreshold {
            return "Move closer to the controller."
        }

        if lockZoneBluetoothRSSI == nil {
            return "Checking Bluetooth signal."
        }

        return "Preparing secure control."
    }

    var secureLinkStatusDetail: String {
        guard isReady, !isDoorCommandReady else {
            return "Bluetooth is on. This iPhone is paired with the lock."
        }

        let threshold = Self.reliableProximityUnlockRSSIThreshold
        if let lockZoneBluetoothRSSI,
           lockZoneBluetoothRSSI < threshold {
            return "Current signal is \(lockZoneBluetoothRSSI) dBm. Get to \(threshold) dBm or stronger."
        }

        if lockZoneBluetoothRSSI == nil {
            return "The app is reading signal strength before secure control is enabled."
        }

        return "The app is requesting a fresh encrypted command nonce from the controller."
    }

    var connectedDevicesTitle: String {
        "\(connectedDeviceCount) of \(max(maximumConnectedDeviceCount, 4)) connected"
    }

    var connectedDevicesDetail: String {
        if connectedDevices.isEmpty {
            return connectedDeviceCount > 0 ? "Connected devices are identifying." : "No other devices are connected."
        }

        return connectedDevices.map(\.displayName).joined(separator: ", ")
    }

    private var hasTrustedPairingForSecureCommand: Bool {
        isPaired || hasKnownPairedController
    }

    private var isSecureCommandWriteReady: Bool {
        commandCharacteristic != nil &&
            peripheral?.state == .connected &&
            hasTrustedPairingForSecureCommand
    }

    private var hasKnownController: Bool {
        peripheral != nil || UserDefaults.standard.string(forKey: Self.knownPeripheralIdentifierKey) != nil
    }

    var canPair: Bool {
        isConnectedToController && pairingState == "Pairing enabled"
    }

    var needsUsbPairingMode: Bool {
        isConnectedToController && pairingState == "Pairing locked"
    }

    var isPairingPending: Bool {
        pairingState == "Pairing pending" || pairingState == "Pairing"
    }

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
        autoLockApplyTask != nil ||
            pendingAutoLockTimeoutSeconds != nil ||
            queuedAutoLockTimeoutSeconds != nil ||
            servoAnglesApplyTask != nil ||
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
            return Self.settingApplyTitle(for: "lock_name", value: Self.shortSettingValue(value))
        }

        if let value = pendingDeviceDisplayName ?? sentDeviceDisplayName {
            return Self.settingApplyTitle(for: "device_name", value: Self.shortSettingValue(value))
        }

        if servoAnglesApplyTask != nil || pendingServoAngles != nil || queuedServoAngles != nil || sentServoAngles != nil {
            let angles = pendingServoAngles ?? queuedServoAngles ?? sentServoAngles ?? ServoAngles(lockAngle: servoLockAngle, unlockAngle: servoUnlockAngle)
            return Self.settingApplyTitle(for: "servo_angles", value: Self.settingApplyValue(for: angles))
        }

        if autoLockApplyTask != nil || pendingAutoLockTimeoutSeconds != nil || queuedAutoLockTimeoutSeconds != nil {
            let seconds = pendingAutoLockTimeoutSeconds ?? queuedAutoLockTimeoutSeconds ?? autoLockSeconds
            return Self.settingApplyTitle(for: "timeout", value: "\(seconds)s")
        }

        if let remoteSettingApplyKind {
            return Self.settingApplyTitle(for: remoteSettingApplyKind, value: Self.displayValue(for: remoteSettingApplyKind, rawValue: remoteSettingApplyValue))
        }

        return "Applying setting"
    }

    private static func settingApplyTitle(for kind: String, value: String? = nil) -> String {
        switch kind {
        case "lock_name":
            return value.map { "Lock name to \($0)" } ?? "Saving lock name"
        case "device_name":
            return value.map { "Device name to \($0)" } ?? "Saving device name"
        case "servo_angles":
            return value.map { "Angles to \($0)" } ?? "Updating angles"
        case "timeout":
            return value.map { "Auto-lock to \($0)" } ?? "Updating auto-lock"
        default:
            return "Applying setting"
        }
    }

    private static func settingApplyValue(for angles: ServoAngles) -> String {
        "\(angles.lockAngle)° / \(angles.unlockAngle)°"
    }

    private static func displayValue(for kind: String, rawValue: String?) -> String? {
        guard let rawValue else { return nil }

        switch kind {
        case "lock_name", "device_name":
            return shortSettingValue(rawValue)
        case "servo_angles":
            let parts = rawValue.split(separator: ",", maxSplits: 1).map(String.init)
            guard parts.count == 2,
                  let lockAngle = Int(parts[0].trimmingCharacters(in: .whitespacesAndNewlines)),
                  let unlockAngle = Int(parts[1].trimmingCharacters(in: .whitespacesAndNewlines)) else {
                return shortSettingValue(rawValue)
            }
            return settingApplyValue(for: ServoAngles(lockAngle: lockAngle, unlockAngle: unlockAngle))
        case "timeout":
            let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedValue.isEmpty else { return nil }
            return trimmedValue.hasSuffix("s") ? trimmedValue : "\(trimmedValue)s"
        default:
            return shortSettingValue(rawValue)
        }
    }

    private static func formattedDistance(_ meters: Double, unit: DistanceUnit) -> String {
        switch unit {
        case .meters:
            guard meters >= 1000 else { return "\(Int(meters.rounded())) m" }
            return String(format: "%.1f km", meters / 1000)
        case .feet:
            return "\(Int((meters * 3.28084).rounded())) ft"
        }
    }

    func formattedDistance(_ meters: Double) -> String {
        Self.formattedDistance(meters, unit: distanceUnit)
    }

    private static func shortSettingValue(_ value: String, maxLength: Int = 18) -> String? {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else { return nil }
        guard trimmedValue.count > maxLength else { return trimmedValue }

        let endIndex = trimmedValue.index(trimmedValue.startIndex, offsetBy: maxLength)
        return "\(trimmedValue[..<endIndex])..."
    }

    private var hasKnownLockState: Bool {
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
            return isReady ? "Ready" : connectionState
        }
    }

    var autoLockRange: ClosedRange<Int> {
        Self.minimumAutoLockSeconds ... Self.maximumAutoLockSeconds
    }

    var servoAngleRange: ClosedRange<Int> {
        Self.minimumServoAngle ... Self.maximumServoAngle
    }

    var servoAnglesAreAtDefaults: Bool {
        servoLockAngle == Self.defaultServoLockAngle && servoUnlockAngle == Self.defaultServoUnlockAngle
    }

    var unlockHoldDurationRange: ClosedRange<Double> {
        Self.minimumUnlockHoldDurationSeconds ... Self.maximumUnlockHoldDurationSeconds
    }

    var lockZoneRadiusRange: ClosedRange<Double> {
        Self.minimumLockZoneRadiusMeters ... Self.maximumLockZoneRadiusMeters
    }

    var proximityUnlockRSSIThresholdRange: ClosedRange<Int> {
        Self.minimumProximityUnlockRSSIThreshold ... Self.maximumProximityUnlockRSSIThreshold
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
                return "Armed. Waiting for \(threshold) dBm or stronger. Current \(lockZoneBluetoothRSSI) dBm."
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

    override init() {
        super.init()
        resetSavedPeripheralIfIdentityChanged()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillTerminate),
            name: UIApplication.willTerminateNotification,
            object: nil
        )
        Task.detached(priority: .userInitiated) {
            DoorCommandAuthenticator.prewarm()
        }
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.distanceFilter = kCLDistanceFilterNone
        locationManager.activityType = .otherNavigation
        locationManager.pausesLocationUpdatesAutomatically = false
        locationManager.allowsBackgroundLocationUpdates = proximityUnlockEnabled
        central = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [
                CBCentralManagerOptionRestoreIdentifierKey: Self.centralRestorationIdentifier
            ]
        )
        UserDefaults.standard.removeObject(forKey: Self.legacyProximityUnlockArmedAtKey)
        if proximityUnlockArmedAt != nil {
            beginProximityUnlockBackgroundTask()
        }
        refreshNotificationSettings()
        updateProximityUnlockStatus()
        restartLockZoneMonitoring()
        dismissStoredLockedLiveActivityIfNeeded()
    }

    private func resetSavedPeripheralIfIdentityChanged() {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: Self.knownPeripheralIdentityVersionKey) != Self.currentPeripheralIdentityVersion else {
            return
        }

        defaults.removeObject(forKey: Self.knownPeripheralIdentifierKey)
        defaults.set(Self.currentPeripheralIdentityVersion, forKey: Self.knownPeripheralIdentityVersionKey)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private static func storedProximityUnlockEnabled() -> Bool {
        UserDefaults.standard.bool(forKey: proximityUnlockKey)
    }

    private static func storedProximityUnlockRSSIThreshold() -> Int? {
        guard UserDefaults.standard.object(forKey: proximityUnlockRSSIThresholdKey) != nil else {
            return nil
        }

        return clampedProximityUnlockRSSIThreshold(UserDefaults.standard.integer(forKey: proximityUnlockRSSIThresholdKey))
    }

    private static func storedDistanceUnit() -> DistanceUnit {
        guard let rawValue = UserDefaults.standard.string(forKey: distanceUnitKey),
              let unit = DistanceUnit(rawValue: rawValue) else {
            return .meters
        }

        return unit
    }

    private static func storedProximityUnlockArmedAt() -> Date? {
        guard storedProximityUnlockEnabled(),
              storedLockZoneCenter() != nil,
              UserDefaults.standard.bool(forKey: lockZoneOutsideKey) else {
            UserDefaults.standard.removeObject(forKey: proximityUnlockArmedAtKey)
            return nil
        }

        let timestamp = UserDefaults.standard.double(forKey: proximityUnlockArmedAtKey)
        guard timestamp > 0 else { return nil }

        let armedAt = Date(timeIntervalSince1970: timestamp)
        guard Date().timeIntervalSince(armedAt) <= maximumStoredProximityUnlockArmAge else {
            UserDefaults.standard.removeObject(forKey: proximityUnlockArmedAtKey)
            return nil
        }

        return armedAt
    }

    private static func storedAutoLockSeconds() -> Int {
        let storedValue = UserDefaults.standard.integer(forKey: autoLockSecondsKey)
        let seconds = storedValue == 0 ? defaultAutoLockSeconds : storedValue
        return clampedAutoLockSeconds(seconds)
    }

    private static func storedLastUnlockAt() -> Date? {
        let timestamp = UserDefaults.standard.double(forKey: lastUnlockAtKey)
        guard timestamp > 0 else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }

    private static func storedLastUnlockDeviceIdentifier() -> String {
        guard let identifier = UserDefaults.standard.string(forKey: lastUnlockDeviceIdentifierKey) else {
            return ""
        }

        return sanitizedTrustedDeviceIdentifier(identifier)
    }

    private static func storedLastUnlockDeviceName() -> String {
        guard let name = UserDefaults.standard.string(forKey: lastUnlockDeviceNameKey) else {
            return ""
        }

        return sanitizedDeviceDisplayName(name)
    }

    private static func sanitizedTrustedDeviceIdentifier(_ identifier: String) -> String {
        let normalized = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let ascii = normalized.unicodeScalars.compactMap { scalar -> String? in
            scalar.isASCII && scalar.value >= 33 && scalar.value <= 126 ? String(scalar) : nil
        }
        return String(ascii.joined().prefix(32))
    }

    private static func storedLockZoneCenter() -> CLLocationCoordinate2D? {
        guard UserDefaults.standard.object(forKey: lockZoneLatitudeKey) != nil,
              UserDefaults.standard.object(forKey: lockZoneLongitudeKey) != nil else {
            return nil
        }

        let latitude = UserDefaults.standard.double(forKey: lockZoneLatitudeKey)
        let longitude = UserDefaults.standard.double(forKey: lockZoneLongitudeKey)
        guard CLLocationCoordinate2DIsValid(CLLocationCoordinate2D(latitude: latitude, longitude: longitude)) else {
            return nil
        }

        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    private static func storedLockZoneRadiusMeters() -> Double {
        let storedValue = UserDefaults.standard.double(forKey: lockZoneRadiusKey)
        let radius = storedValue == 0 ? defaultLockZoneRadiusMeters : storedValue
        return clampedLockZoneRadiusMeters(radius)
    }

    private static func storedLockZoneUpdatedAt() -> Date? {
        let timestamp = UserDefaults.standard.double(forKey: lockZoneUpdatedAtKey)
        guard timestamp > 0 else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }

    private static func storedUnlockHoldDurationSeconds() -> Double {
        let storedValue = UserDefaults.standard.double(forKey: unlockHoldDurationKey)
        let seconds = storedValue == 0 ? defaultUnlockHoldDurationSeconds : storedValue
        return clampedUnlockHoldDurationSeconds(seconds)
    }

    private static func storedDeviceDisplayName() -> String {
        if let storedName = UserDefaults.standard.string(forKey: deviceDisplayNameKey) {
            let sanitizedName = sanitizedDeviceDisplayName(storedName)
            if !sanitizedName.isEmpty {
                return sanitizedName
            }
        }

        return sanitizedDeviceDisplayName(UIDevice.current.name)
    }

    private static func sanitizedDeviceDisplayName(_ name: String) -> String {
        let normalized = normalizedDeviceNameSource(name)
        let fallback = normalized.isEmpty ? "iPhone" : normalized
        let ascii = fallback.unicodeScalars.compactMap { scalar -> String? in
            scalar.isASCII && scalar.value >= 32 && scalar.value <= 126 ? String(scalar) : nil
        }
        return String(ascii.joined().prefix(maximumDeviceDisplayNameLength)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedDeviceNameSource(_ name: String) -> String {
        name
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{201B}", with: "'")
            .replacingOccurrences(of: "\u{2032}", with: "'")
            .replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
            .replacingOccurrences(of: "\u{201E}", with: "\"")
            .replacingOccurrences(of: "\u{2033}", with: "\"")
            .replacingOccurrences(of: "\u{2010}", with: "-")
            .replacingOccurrences(of: "\u{2011}", with: "-")
            .replacingOccurrences(of: "\u{2012}", with: "-")
            .replacingOccurrences(of: "\u{2013}", with: "-")
            .replacingOccurrences(of: "\u{2014}", with: "-")
            .replacingOccurrences(of: "\u{2026}", with: "...")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func clampedAutoLockSeconds(_ seconds: Int) -> Int {
        min(max(seconds, minimumAutoLockSeconds), maximumAutoLockSeconds)
    }

    private static func clampedUnlockHoldDurationSeconds(_ seconds: Double) -> Double {
        let clampedSeconds = min(max(seconds, minimumUnlockHoldDurationSeconds), maximumUnlockHoldDurationSeconds)
        return (clampedSeconds * 4).rounded() / 4
    }

    private static func clampedLockZoneRadiusMeters(_ meters: Double) -> Double {
        min(max((meters / 5).rounded() * 5, minimumLockZoneRadiusMeters), maximumLockZoneRadiusMeters)
    }

    private static func clampedProximityUnlockRSSIThreshold(_ rssi: Int) -> Int {
        min(max(rssi, minimumProximityUnlockRSSIThreshold), maximumProximityUnlockRSSIThreshold)
    }

    private static func clampedServoAngles(_ angles: ServoAngles) -> ServoAngles {
        ServoAngles(
            lockAngle: min(max(angles.lockAngle, minimumServoAngle), maximumServoAngle),
            unlockAngle: min(max(angles.unlockAngle, minimumServoAngle), maximumServoAngle)
        )
    }

    private static func servoAnglesAreValid(_ angles: ServoAngles) -> Bool {
        servoAngleIsSafe(angles.lockAngle)
            && servoAngleIsSafe(angles.unlockAngle)
            && abs(angles.lockAngle - angles.unlockAngle) >= minimumServoAngleGap
    }

    private static func servoAngleIsSafe(_ angle: Int) -> Bool {
        angle >= minimumServoAngle && angle <= maximumServoAngle
    }

    func setRequiresUnlockAuthentication(_ isRequired: Bool) {
        guard isRequired != requiresUnlockAuthentication else { return }
        guard areSettingsUnlocked else {
            lastError = "Open Settings with Face ID or passcode first"
            return
        }

        requiresUnlockAuthentication = isRequired
        UserDefaults.standard.set(isRequired, forKey: Self.unlockAuthenticationKey)
    }

    func setRequiresHoldToUnlock(_ isRequired: Bool) {
        guard isRequired != requiresHoldToUnlock else { return }
        guard areSettingsUnlocked else {
            lastError = "Open Settings with Face ID or passcode first"
            return
        }

        requiresHoldToUnlock = isRequired
        UserDefaults.standard.set(isRequired, forKey: Self.unlockHoldRequirementKey)
    }

    func updateUnlockHoldDurationSeconds(_ seconds: Double) {
        let clampedSeconds = Self.clampedUnlockHoldDurationSeconds(seconds)
        guard clampedSeconds != unlockHoldDurationSeconds else { return }
        guard areSettingsUnlocked else {
            lastError = "Open Settings with Face ID or passcode first"
            return
        }

        unlockHoldDurationSeconds = clampedSeconds
        UserDefaults.standard.set(clampedSeconds, forKey: Self.unlockHoldDurationKey)
    }

    func setUnlockNotificationsEnabled(_ isEnabled: Bool) {
        guard isEnabled != unlockNotificationsEnabled else { return }
        guard areSettingsUnlocked else {
            lastError = "Open Settings with Face ID or passcode first"
            return
        }

        if isEnabled {
            requestUnlockNotificationAuthorization()
        } else {
            unlockNotificationsEnabled = false
            unlockNotificationStatus = "Off"
            UserDefaults.standard.set(false, forKey: Self.unlockNotificationsKey)
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.unlockNotificationIdentifier])
        }
    }

    func setProximityUnlockEnabled(_ isEnabled: Bool) {
        guard isEnabled != proximityUnlockEnabled else { return }
        guard areSettingsUnlocked else {
            lastError = "Open Settings with Face ID or passcode first"
            return
        }

        proximityUnlockEnabled = isEnabled
        UserDefaults.standard.set(isEnabled, forKey: Self.proximityUnlockKey)
        locationManager.allowsBackgroundLocationUpdates = isEnabled
        if isEnabled {
            requestLocationAuthorizationIfNeeded()
            requestBackgroundReliabilityNotificationAuthorizationIfNeeded()
        }

        if isReady || !isEnabled {
            clearProximityUnlockArming()
        } else {
            clearProximityUnlockCandidate()
        }

        restartLockZoneMonitoring()
        if isEnabled {
            armProximityUnlockIfOutsideAndDisconnected()
        } else {
            cancelBackgroundReliabilityWarning()
            updateProximityUnlockStatus()
        }
    }

    func setProximityUnlockRSSIGateEnabled(_ isEnabled: Bool) {
        guard isEnabled != proximityUnlockRSSIGateEnabled else { return }
        guard areSettingsUnlocked else {
            lastError = "Open Settings with Face ID or passcode first"
            return
        }

        if isEnabled {
            let threshold = proximityUnlockRSSIThreshold ?? Self.defaultProximityUnlockRSSIThreshold
            proximityUnlockRSSIThreshold = threshold
            UserDefaults.standard.set(threshold, forKey: Self.proximityUnlockRSSIThresholdKey)
            peripheral?.readRSSI()
        } else {
            proximityUnlockRSSIThreshold = nil
            UserDefaults.standard.removeObject(forKey: Self.proximityUnlockRSSIThresholdKey)
        }

        updateProximityUnlockStatus()
        if proximityUnlockArmedAt != nil {
            _ = runProximityUnlockIfReady()
        }
    }

    func updateProximityUnlockRSSIThreshold(_ rssi: Int) {
        let threshold = Self.clampedProximityUnlockRSSIThreshold(rssi)
        guard threshold != proximityUnlockRSSIThreshold else { return }
        guard areSettingsUnlocked else {
            lastError = "Open Settings with Face ID or passcode first"
            return
        }

        proximityUnlockRSSIThreshold = threshold
        UserDefaults.standard.set(threshold, forKey: Self.proximityUnlockRSSIThresholdKey)
        peripheral?.readRSSI()
        updateProximityUnlockStatus()
        if proximityUnlockArmedAt != nil {
            _ = runProximityUnlockIfReady()
        }
    }

    func setDistanceUnit(_ unit: DistanceUnit) {
        guard unit != distanceUnit else { return }
        guard areSettingsUnlocked else {
            lastError = "Open Settings with Face ID or passcode first"
            return
        }

        distanceUnit = unit
        UserDefaults.standard.set(unit.rawValue, forKey: Self.distanceUnitKey)
    }

    func updateLockZoneRadiusMeters(_ meters: Double) {
        let clampedMeters = Self.clampedLockZoneRadiusMeters(meters)
        guard clampedMeters != lockZoneRadiusMeters else { return }
        guard areSettingsUnlocked else {
            lastError = "Open Settings with Face ID or passcode first"
            return
        }

        lockZoneRadiusMeters = clampedMeters
        UserDefaults.standard.set(clampedMeters, forKey: Self.lockZoneRadiusKey)
        updateLockZoneLocationSnapshotIfPossible()
        if lockZoneStatus != "Left zone" && lockZoneStatus != "Inside zone" {
            lockZoneStatus = "Radius \(formattedDistance(clampedMeters))"
        }
        restartLockZoneMonitoring()
    }

    func setLockZoneToCurrentLocation() {
        guard areSettingsUnlocked else {
            lastError = "Open Settings with Face ID or passcode first"
            return
        }

        requestCurrentLocation(for: .setLockZoneFromSettings)
    }

    func refreshLockZoneLocation() {
        requestLockZoneLocationSnapshotIfAvailable()
    }

    func startLockZoneLocationUpdates() {
        guard lockZoneCenter != nil else { return }

        isLockZoneLocationUpdating = true
        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            startBestAvailableLocationUpdates()
            if locationManager.authorizationStatus == .authorizedWhenInUse {
                requestAlwaysLocationAuthorizationIfNeeded()
            }
        case .denied, .restricted:
            lockZoneStatus = "Location off"
        @unknown default:
            lockZoneStatus = "Location unavailable"
        }
    }

    func stopLockZoneLocationUpdates() {
        isLockZoneLocationUpdating = false
        locationManager.stopUpdatingLocation()
    }

    func startLockZoneDirectionUpdates() {
        guard CLLocationManager.headingAvailable() else {
            lockZoneHeadingDegrees = nil
            return
        }

        locationManager.headingFilter = 3
        locationManager.startUpdatingHeading()
    }

    func stopLockZoneDirectionUpdates() {
        locationManager.stopUpdatingHeading()
        lockZoneHeadingDegrees = nil
        lockZoneHeadingAccuracyDegrees = nil
    }

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

    func updateAutoLockSeconds(_ seconds: Int) {
        let clampedSeconds = Self.clampedAutoLockSeconds(seconds)
        guard clampedSeconds != autoLockSeconds else { return }
        guard areSettingsUnlocked else {
            lastError = "Open Settings with Face ID or passcode first"
            return
        }

        autoLockSeconds = clampedSeconds
        UserDefaults.standard.set(autoLockSeconds, forKey: Self.autoLockSecondsKey)
        scheduleAutoLockTimeoutApply()
    }

    func updateServoLockAngle(_ angle: Int) {
        updateServoAngles(ServoAngles(lockAngle: angle, unlockAngle: servoUnlockAngle))
    }

    func updateServoUnlockAngle(_ angle: Int) {
        updateServoAngles(ServoAngles(lockAngle: servoLockAngle, unlockAngle: angle))
    }

    func resetServoAnglesToDefaults() {
        updateServoAngles(ServoAngles(
            lockAngle: Self.defaultServoLockAngle,
            unlockAngle: Self.defaultServoUnlockAngle
        ))
    }

    private func updateServoAngles(_ requestedAngles: ServoAngles) {
        let angles = Self.clampedServoAngles(requestedAngles)
        guard Self.servoAnglesAreValid(angles) else {
            lastError = "Keep servo angles \(Self.minimumServoAngleGap) degrees apart and inside \(Self.minimumServoAngle)-\(Self.maximumServoAngle) degrees."
            return
        }
        guard angles.lockAngle != servoLockAngle || angles.unlockAngle != servoUnlockAngle || pendingServoAngles != nil else { return }
        guard areSettingsUnlocked else {
            lastError = "Open Settings with Face ID or passcode first"
            return
        }

        servoLockAngle = angles.lockAngle
        servoUnlockAngle = angles.unlockAngle
        pendingServoAngles = angles
        servoAnglesStatus = isReady ? "Setting..." : "Waiting for controller"
        scheduleServoAnglesApply()
    }

    func updateDeviceDisplayName(_ name: String) {
        let sanitizedName = Self.sanitizedDeviceDisplayName(name)
        guard !sanitizedName.isEmpty else { return }
        guard areSettingsUnlocked else {
            lastError = "Open Settings with Face ID or passcode first"
            return
        }

        if sanitizedName != deviceDisplayName {
            deviceDisplayName = sanitizedName
            UserDefaults.standard.set(sanitizedName, forKey: Self.deviceDisplayNameKey)
            lastSyncedDeviceDisplayName = nil
        }

        pendingDeviceDisplayName = sanitizedName
        deviceDisplayNameStatus = isReady ? "Setting..." : "Waiting for controller"
        syncDeviceDisplayNameIfReady()
    }

    func updateLockName(_ name: String) {
        let sanitizedName = DoorStatusStore.sanitizedLockName(name)
        guard !sanitizedName.isEmpty else { return }
        guard areSettingsUnlocked else {
            lastError = "Open Settings with Face ID or passcode first"
            return
        }

        if sanitizedName == lockName && lastSyncedLockName == sanitizedName {
            lockNameStatus = "Controller name set"
            return
        }

        if sanitizedName != lockName {
            lockName = sanitizedName
            DoorStatusStore.saveLockName(sanitizedName)
            requestDoorWidgetReload()
        }

        pendingLockName = sanitizedName
        lockNameStatus = isReady ? "Setting..." : "Waiting for controller"
        syncLockNameIfReady()
    }

    func unlockSettings() {
        guard !areSettingsUnlocked, !isAuthenticatingSettings else { return }

        Task { [weak self] in
            await self?.authenticateSettingsAccess()
        }
    }

    func lockSettings() {
        areSettingsUnlocked = false
    }

    private func applyRemoteSettingApplying(kind: String, value: String?) {
        remoteSettingApplyTask?.cancel()
        remoteSettingApplyValue = value
        remoteSettingApplyKind = kind
        remoteSettingApplyTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.clearRemoteSettingApplying()
            }
        }
    }

    private func clearRemoteSettingApplying() {
        remoteSettingApplyTask?.cancel()
        remoteSettingApplyTask = nil
        remoteSettingApplyKind = nil
        remoteSettingApplyValue = nil
    }

    private func scheduleAutoLockTimeoutApply() {
        autoLockApplyTask?.cancel()
        autoLockStatus = isReady ? "Setting..." : "Waiting for controller"

        autoLockApplyTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }

            await MainActor.run {
                self?.autoLockApplyTask = nil
                self?.applyAutoLockTimeout()
            }
        }
    }

    private func applyAutoLockTimeout() {
        guard isReady else {
            queuedAutoLockTimeoutSeconds = autoLockSeconds
            autoLockStatus = "Waiting for controller"
            scan()
            return
        }

        let commandText = "SET_TIMEOUT:\(autoLockSeconds)"
        pendingAutoLockTimeoutSeconds = autoLockSeconds
        autoLockStatus = "Setting..."

        if !writeAuthenticatedCommand(commandText, intent: .autoLockTimeout(autoLockSeconds)) {
            pendingAutoLockTimeoutSeconds = nil
            autoLockStatus = "Not set"
        }
    }

    private func scheduleServoAnglesApply() {
        servoAnglesApplyTask?.cancel()
        servoAnglesStatus = isReady ? "Setting..." : "Waiting for controller"

        servoAnglesApplyTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }

            await MainActor.run {
                self?.servoAnglesApplyTask = nil
                self?.applyServoAngles()
            }
        }
    }

    private func applyServoAngles() {
        let angles = pendingServoAngles ?? ServoAngles(lockAngle: servoLockAngle, unlockAngle: servoUnlockAngle)
        guard Self.servoAnglesAreValid(angles) else {
            servoAnglesStatus = "Not set"
            lastError = "Servo angles must stay inside \(Self.minimumServoAngle)-\(Self.maximumServoAngle) degrees and \(Self.minimumServoAngleGap) degrees apart."
            return
        }

        guard isReady else {
            queuedServoAngles = angles
            servoAnglesStatus = "Waiting for controller"
            scan()
            return
        }

        pendingServoAngles = angles
        sentServoAngles = angles
        servoAnglesStatus = "Setting..."

        if !writeAuthenticatedCommand("SET_ANGLES:\(angles.lockAngle),\(angles.unlockAngle)", intent: .servoAngles(angles)) {
            sentServoAngles = nil
            servoAnglesStatus = "Not set"
        }
    }

    private func applyControllerAutoLockTimeout(_ seconds: Int) {
        clearRemoteSettingApplying()
        let confirmedSeconds = Self.clampedAutoLockSeconds(seconds)

        if pendingAutoLockTimeoutSeconds == confirmedSeconds {
            pendingAutoLockTimeoutSeconds = nil
        }

        if queuedAutoLockTimeoutSeconds == confirmedSeconds {
            queuedAutoLockTimeoutSeconds = nil
        }

        let hasNewerLocalIntent = autoLockSeconds != confirmedSeconds
            && (autoLockApplyTask != nil || pendingAutoLockTimeoutSeconds != nil || queuedAutoLockTimeoutSeconds != nil)

        guard !hasNewerLocalIntent else {
            autoLockStatus = isReady ? "Setting..." : "Waiting for controller"
            return
        }

        autoLockSeconds = confirmedSeconds
        UserDefaults.standard.set(autoLockSeconds, forKey: Self.autoLockSecondsKey)
        autoLockStatus = "Controller set to \(autoLockSeconds)s"
    }

    private func applyControllerServoAngles(_ angles: ServoAngles) {
        clearRemoteSettingApplying()
        let confirmedAngles = Self.clampedServoAngles(angles)
        guard Self.servoAnglesAreValid(confirmedAngles) else { return }

        if pendingServoAngles == confirmedAngles {
            pendingServoAngles = nil
        }
        if queuedServoAngles == confirmedAngles {
            queuedServoAngles = nil
        }
        if sentServoAngles == confirmedAngles {
            sentServoAngles = nil
        }

        let currentAngles = ServoAngles(lockAngle: servoLockAngle, unlockAngle: servoUnlockAngle)
        let hasNewerLocalIntent = currentAngles != confirmedAngles
            && (servoAnglesApplyTask != nil || pendingServoAngles != nil || queuedServoAngles != nil || sentServoAngles != nil)

        guard !hasNewerLocalIntent else {
            servoAnglesStatus = isReady ? "Setting..." : "Waiting for controller"
            return
        }

        servoLockAngle = confirmedAngles.lockAngle
        servoUnlockAngle = confirmedAngles.unlockAngle
        servoAnglesStatus = "Controller set to \(confirmedAngles.lockAngle)° / \(confirmedAngles.unlockAngle)°"
    }

    func scan() {
        guard central?.state == .poweredOn else {
            connectionState = "Bluetooth off"
            return
        }

        lastError = nil
        reconnectTimer?.invalidate()

        if let peripheral, peripheral.state == .connected {
            connectionState = commandCharacteristic == nil ? "Discovering" : "Ready"
            if commandCharacteristic == nil {
                peripheral.discoverServices([serviceUUID])
            }
            readStateIfPermitted()
            updateProximityUnlockStatus()
            return
        }

        clearDiscoveredControllerCharacteristics()
        hasRequestedControllerLockName = false
        hasRequestedControllerServoAngles = false
        hasRequestedControllerLastUnlock = false
        pairingState = "Unknown"
        pairingApprovalCode = nil
        updateProximityUnlockStatus()

        if connectToKnownPeripheralIfPossible() {
            return
        }

        startScan()
    }

    func refreshStateFromController() {
        reconcilePredictedAutoLock()
        if !readStateIfPermitted() {
            scan()
        }
    }

    func toggleLock() {
        send(isUnlocked ? .lock : .unlock)
    }

    func performPendingSystemCommand() {
        guard let systemCommand = DoorCommandStore.takePendingCommand() else { return }
        runSystemCommand(systemCommand)
    }

    func send(_ command: Command) {
        if command == .unlock && requiresUnlockAuthentication {
            Task {
                await authenticateAndSendUnlock()
            }
            return
        }

        sendAuthenticated(command)
    }

    @discardableResult
    private func sendAuthenticated(_ command: Command, origin: DoorCommandOrigin = .manual) -> Bool {
        sendDoorCommandAttempt(
            command,
            attempt: 1,
            previousServoState: stableDoorStateForRecovery(),
            origin: origin
        )
    }

    @discardableResult
    private func sendDoorCommandAttempt(_ command: Command, attempt: Int, previousServoState: String?, origin: DoorCommandOrigin) -> Bool {
        let commandSentAt = Date()
        let unlockSentAt = command == .unlock ? commandSentAt : nil
        let commandText = command.commandText
        let didWrite = writeAuthenticatedCommand(commandText, intent: .doorCommand(command, unlockSentAt, origin))
        if didWrite {
            optimisticDoorCommand = command
            optimisticDoorCommandOrigin = origin
            optimisticDoorCommandSentAt = commandSentAt
            optimisticDoorCommandAttempt = attempt
            optimisticDoorPreviousServoState = previousServoState
            servoState = command == .unlock ? "unlocking" : "locking"
            lastError = nil
            publishWidgetState(servoState, resetAutoLockDeadline: command == .unlock)
            scheduleDoorCommandRecovery(command, sentAt: commandSentAt, attempt: attempt, origin: origin)
        }
        return didWrite
    }

    private func scheduleDoorCommandRecovery(_ command: Command, sentAt: Date, attempt: Int, origin: DoorCommandOrigin) {
        doorCommandRecoveryTask?.cancel()
        doorCommandRecoveryTask = Task { [weak self] in
            let readDelays: [UInt64] = [1_500_000_000, 3_000_000_000]
            for delay in readDelays {
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled else { return }

                let shouldContinue = await MainActor.run {
                    guard let self,
                          self.optimisticDoorCommand == command,
                          self.optimisticDoorCommandSentAt == sentAt,
                          self.optimisticDoorCommandAttempt == attempt,
                          self.isChangingState else {
                        return false
                    }
                    _ = self.readStateIfPermitted()
                    return true
                }

                if !shouldContinue {
                    return
                }
            }

            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard let self,
                      self.optimisticDoorCommand == command,
                      self.optimisticDoorCommandSentAt == sentAt,
                      self.optimisticDoorCommandAttempt == attempt,
                      self.isChangingState else {
                    return
                }

                let restoredState = self.stableRestoredDoorState()
                self.clearOptimisticDoorCommand()
                self.servoState = restoredState
                self.lastError = "Controller did not confirm \(command == .unlock ? "unlock" : "lock")."
                if restoredState == "locked" || restoredState == "unlocked" {
                    self.publishWidgetState(restoredState)
                }
                if origin == .proximity {
                    self.endProximityUnlockBackgroundTask()
                    if command == .unlock && restoredState != "unlocked" {
                        self.restoreProximityUnlockAfterInterruptedCommand()
                    }
                }
            }
        }
    }

    private func rejectOptimisticDoorCommand(_ command: Command) {
        let origin = optimisticDoorCommandOrigin
        let restoredState = stableRestoredDoorState()
        clearOptimisticDoorCommand()
        servoState = restoredState
        lastError = "Controller rejected \(command == .unlock ? "unlock" : "lock")."
        updatePairingState(from: restoredState)
        if restoredState == "locked" || restoredState == "unlocked" {
            publishWidgetState(restoredState)
        }
        if origin == .proximity, command == .unlock, restoredState != "unlocked" {
            endProximityUnlockBackgroundTask()
            restoreProximityUnlockAfterInterruptedCommand()
        } else if origin == .proximity {
            endProximityUnlockBackgroundTask()
        }
        _ = readStateIfPermitted()
    }

    private func finalDoorState(for command: Command) -> String {
        command == .unlock ? "unlocked" : "locked"
    }

    private func settleOptimisticDoorCommand(_ command: Command) {
        let origin = optimisticDoorCommandOrigin
        if command == .unlock, let optimisticDoorCommandSentAt {
            applyKnownLastUnlock(
                optimisticDoorCommandSentAt,
                deviceName: deviceDisplayName,
                updateLockZone: true
            )
        }

        let finalState = finalDoorState(for: command)
        clearOptimisticDoorCommand()
        servoState = finalState
        lastError = nil
        updatePairingState(from: finalState)
        publishWidgetState(finalState, resetAutoLockDeadline: command == .unlock)
        if origin == .proximity {
            endProximityUnlockBackgroundTask()
        }
        _ = readStateIfPermitted()
    }

    private func stableDoorStateForRecovery() -> String? {
        if servoState == "locked" || servoState == "unlocked" {
            return servoState
        }

        let snapshotState = DoorStatusStore.load().state
        if snapshotState == "locked" || snapshotState == "unlocked" {
            return snapshotState
        }

        return nil
    }

    private func stableRestoredDoorState() -> String {
        if let optimisticDoorPreviousServoState {
            return optimisticDoorPreviousServoState
        }

        return stableDoorStateForRecovery() ?? "unknown"
    }

    @discardableResult
    private func writeAuthenticatedCommand(_ commandText: String, intent: CommandWriteIntent) -> Bool {
        guard let peripheral, let commandCharacteristic else {
            lastError = "Not connected"
            return false
        }

        guard hasTrustedPairingForSecureCommand else {
            lastError = "Pair this iPhone before sending commands"
            return false
        }

        let doorCommand: Command?
        if case .doorCommand(let command, _, _) = intent {
            doorCommand = command
        } else {
            doorCommand = nil
        }

        if let doorCommand,
           let preparedFastPayload = preparedFastDoorCommandPayloads[doorCommand],
           let fastWriteType = preferredFastDoorCommandWriteType(
                for: preparedFastPayload.data,
                peripheral: peripheral,
                characteristic: commandCharacteristic
           ) {
            invalidatePreparedFastDoorCommandPayloads(clearNonce: true)
            lastError = nil
            peripheral.writeValue(preparedFastPayload.data, for: commandCharacteristic, type: fastWriteType)
            return true
        }

        if let doorCommand {
            if preparedFastDoorCommandTask != nil || fastCommandNonce != nil {
                lastError = "Preparing secure \(doorCommand == .unlock ? "unlock" : "lock")."
            } else {
                lastError = "Waiting for controller secure nonce."
            }
            return false
        }

        guard let nonce = fastCommandNonce else {
            lastError = "Waiting for controller secure nonce."
            return false
        }

        let data: Data
        do {
            data = try DoorCommandAuthenticator.secureCommandPayload(for: commandText, nonce: nonce).data
        } catch {
            lastError = error.localizedDescription
            return false
        }

        guard let writeType = preferredWriteType(for: data, intent: intent, peripheral: peripheral, characteristic: commandCharacteristic) else {
            lastError = "Secure command is too large for this BLE connection"
            return false
        }

        lastError = nil
        invalidatePreparedFastDoorCommandPayloads(clearNonce: true)
        if writeType == .withResponse {
            pendingCommandWriteIntents.append(intent)
        }
        peripheral.writeValue(data, for: commandCharacteristic, type: writeType)
        return true
    }

    private func preferredFastDoorCommandWriteType(
        for data: Data,
        peripheral: CBPeripheral,
        characteristic: CBCharacteristic
    ) -> CBCharacteristicWriteType? {
        guard characteristic.properties.contains(.writeWithoutResponse),
              data.count <= peripheral.maximumWriteValueLength(for: .withoutResponse) else {
            return nil
        }

        return .withoutResponse
    }

    private func prepareFastDoorCommandPayloads(for nonce: Data) {
        preparedFastDoorCommandGeneration += 1
        let generation = preparedFastDoorCommandGeneration

        preparedFastDoorCommandTask?.cancel()
        preparedFastDoorCommandTask = Task { [weak self] in
            let payloads = try? await Task.detached(priority: .userInitiated) {
                try DoorCommandAuthenticator.fastCommandPayloads(nonce: nonce)
            }.value

            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard let self,
                      self.preparedFastDoorCommandGeneration == generation,
                      self.fastCommandNonce == nonce,
                      self.hasTrustedPairingForSecureCommand else {
                    return
                }

                guard let payloads else {
                    self.preparedFastDoorCommandTask = nil
                    self.fastCommandNonce = nil
                    self.startSecureLinkWatchdogIfNeeded()
                    return
                }

                self.preparedFastDoorCommandPayloads = payloads
                self.preparedFastDoorCommandTask = nil
                self.stopSecureLinkWatchdog()
                if self.sendPendingFreshNonceDoorCommandIfReady() {
                    return
                }
                self.sendPendingSystemCommandIfReady()
                _ = self.runProximityUnlockIfReady()
                guard self.fastCommandNonce == nonce else { return }
                self.syncLockNameIfReady()
                self.syncDeviceDisplayNameIfReady()
                self.requestControllerLockNameIfReady()
                self.requestControllerServoAnglesIfReady()
                self.requestControllerLastUnlockIfReady()
            }
        }
    }

    private func invalidatePreparedFastDoorCommandPayloads(clearNonce: Bool = false) {
        preparedFastDoorCommandGeneration += 1
        preparedFastDoorCommandTask?.cancel()
        preparedFastDoorCommandTask = nil
        preparedFastDoorCommandPayloads.removeAll()
        if clearNonce {
            fastCommandNonce = nil
        }
    }

    private func applyFastCommandNonce(_ nonce: Data) {
        fastCommandNonce = nonce
        prepareFastDoorCommandPayloads(for: nonce)
    }

    private func preferredWriteType(
        for data: Data,
        intent: CommandWriteIntent,
        peripheral: CBPeripheral,
        characteristic: CBCharacteristic
    ) -> CBCharacteristicWriteType? {
        let canWriteWithoutResponse = characteristic.properties.contains(.writeWithoutResponse)
        let canWriteWithResponse = characteristic.properties.contains(.write)
        let isDoorCommand: Bool
        if case .doorCommand(_, _, _) = intent {
            isDoorCommand = true
        } else {
            isDoorCommand = false
        }

        if isDoorCommand,
           canWriteWithResponse,
           data.count <= peripheral.maximumWriteValueLength(for: .withResponse) {
            return .withResponse
        }

        if canWriteWithResponse,
           data.count <= peripheral.maximumWriteValueLength(for: .withResponse) {
            return .withResponse
        }

        if canWriteWithoutResponse,
           data.count <= peripheral.maximumWriteValueLength(for: .withoutResponse) {
            return .withoutResponse
        }

        return nil
    }

    private func authenticateAndSendUnlock() async {
        guard !isAuthenticatingUnlock else { return }

        lastError = nil
        isAuthenticatingUnlock = true
        defer { isAuthenticatingUnlock = false }

        let context = LAContext()
        context.localizedCancelTitle = "Cancel"

        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            lastError = "Set up Face ID or a device passcode to protect unlock"
            return
        }

        do {
            let allowed = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Authenticate to unlock Door Unlocker."
            )
            guard allowed else { return }
            sendAuthenticated(.unlock)
        } catch {
            if isAuthenticationCancellation(error) {
                lastError = nil
            } else {
                lastError = "Unlock authentication failed"
            }
        }
    }

    private func authenticateSettingsAccess() async {
        guard !isAuthenticatingSettings else { return }

        lastError = nil
        isAuthenticatingSettings = true
        defer { isAuthenticatingSettings = false }

        let context = LAContext()
        context.localizedCancelTitle = "Cancel"

        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            lastError = "Set up Face ID or a device passcode to change settings"
            return
        }

        do {
            let allowed = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Authenticate to open Door Unlocker settings."
            )
            guard allowed else { return }
            areSettingsUnlocked = true
        } catch {
            if isAuthenticationCancellation(error) {
                lastError = nil
            } else {
                lastError = "Settings authentication failed"
            }
        }
    }

    private func isAuthenticationCancellation(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == LAError.errorDomain,
              let code = LAError.Code(rawValue: nsError.code) else {
            return false
        }

        switch code {
        case .userCancel, .systemCancel, .appCancel:
            return true
        default:
            return false
        }
    }

    func pairThisPhone() {
        guard let peripheral, let pairingCharacteristic else {
            lastError = "Pairing characteristic not found"
            return
        }

        do {
            let pairingPayload = try DoorCommandAuthenticator.pairingPayload(deviceName: deviceDisplayName)
            let approvalCode = try DoorCommandAuthenticator.pairingApprovalCode()
            guard pairingPayload.count <= peripheral.maximumWriteValueLength(for: .withResponse) else {
                lastError = "Pairing key is too large for this BLE connection"
                return
            }

            lastError = nil
            pairingApprovalCode = approvalCode
            pairingState = "Pairing"
            peripheral.writeValue(pairingPayload, for: pairingCharacteristic, type: .withResponse)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func syncDeviceDisplayNameIfReady() {
        guard pendingDeviceDisplayName != nil || sentDeviceDisplayName != nil else { return }
        let nameToSync = pendingDeviceDisplayName ?? deviceDisplayName
        guard lastSyncedDeviceDisplayName != nameToSync else {
            if sentDeviceDisplayName == nil {
                pendingDeviceDisplayName = nil
                deviceDisplayNameStatus = "Controller name set"
            }
            return
        }

        if let sentName = sentDeviceDisplayName {
            if sentName != nameToSync {
                pendingDeviceDisplayName = nameToSync
                deviceDisplayNameStatus = "Setting..."
            }
            return
        }

        guard isReady else {
            pendingDeviceDisplayName = nameToSync
            deviceDisplayNameStatus = "Waiting for controller"
            scan()
            return
        }
        guard fastCommandNonce != nil else {
            pendingDeviceDisplayName = nameToSync
            deviceDisplayNameStatus = "Waiting for secure link"
            return
        }

        if writeAuthenticatedCommand("SET_NAME:\(nameToSync)", intent: .deviceDisplayName(nameToSync)) {
            pendingDeviceDisplayName = nil
            sentDeviceDisplayName = nameToSync
            deviceDisplayNameStatus = "Setting..."
            scheduleDeviceDisplayNameRetry()
        } else {
            pendingDeviceDisplayName = nameToSync
            deviceDisplayNameStatus = "Not set"
        }
    }

    private func confirmDeviceDisplayNameSyncIfNeeded() {
        guard let confirmedName = sentDeviceDisplayName else { return }

        clearRemoteSettingApplying()
        deviceDisplayNameSyncTask?.cancel()
        deviceDisplayNameSyncTask = nil
        sentDeviceDisplayName = nil
        lastSyncedDeviceDisplayName = confirmedName

        let nextName = pendingDeviceDisplayName
        if nextName == nil || nextName == confirmedName {
            pendingDeviceDisplayName = nil
            deviceDisplayNameStatus = "Controller name set"
        } else {
            deviceDisplayNameStatus = "Setting..."
            syncDeviceDisplayNameIfReady()
        }
    }

    private func syncLockNameIfReady() {
        guard pendingLockName != nil || sentLockName != nil else { return }
        let nameToSync = pendingLockName ?? lockName
        guard lastSyncedLockName != nameToSync else {
            if sentLockName == nil {
                pendingLockName = nil
                lockNameStatus = "Controller name set"
            }
            return
        }

        if let sentName = sentLockName {
            if sentName != nameToSync {
                pendingLockName = nameToSync
                lockNameStatus = "Setting..."
            }
            return
        }

        guard isReady else {
            pendingLockName = nameToSync
            lockNameStatus = "Waiting for controller"
            scan()
            return
        }
        guard fastCommandNonce != nil else {
            pendingLockName = nameToSync
            lockNameStatus = "Waiting for secure link"
            return
        }

        if writeAuthenticatedCommand("SET_LOCK_NAME:\(nameToSync)", intent: .lockName(nameToSync)) {
            pendingLockName = nil
            sentLockName = nameToSync
            lockNameStatus = "Setting..."
            scheduleLockNameRetry()
        } else {
            pendingLockName = nameToSync
            lockNameStatus = "Not set"
        }
    }

    private func applyControllerLockName(_ name: String) {
        clearRemoteSettingApplying()
        let sanitizedName = DoorStatusStore.sanitizedLockName(name)
        guard !sanitizedName.isEmpty else { return }

        if sentLockName == sanitizedName {
            lockNameSyncTask?.cancel()
            lockNameSyncTask = nil
            sentLockName = nil
            lastSyncedLockName = sanitizedName
        }
        if pendingLockName == sanitizedName {
            pendingLockName = nil
        }

        let hasNewerLocalIntent = lockName != sanitizedName && (pendingLockName != nil || sentLockName != nil)
        guard !hasNewerLocalIntent else {
            lockNameStatus = isReady ? "Setting..." : "Waiting for controller"
            syncLockNameIfReady()
            return
        }

        if lockName != sanitizedName {
            lockName = sanitizedName
            DoorStatusStore.saveLockName(sanitizedName)
            requestDoorWidgetReload()
        }

        lockNameStatus = "Controller name set"
        syncLockNameIfReady()
    }

    private func scheduleLockNameRetry() {
        lockNameSyncTask?.cancel()
        lockNameSyncTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.lockNameSyncTask = nil
            }
            await self?.retryUnconfirmedLockName()
        }
    }

    private func retryUnconfirmedLockName() {
        guard let name = sentLockName else { return }

        sentLockName = nil
        pendingLockName = name
        lockNameStatus = isReady ? "Retrying..." : "Waiting for controller"
        syncLockNameIfReady()
    }

    private func requestControllerLockNameIfReady() {
        guard isReady,
              fastCommandNonce != nil,
              !isChangingState,
              !hasRequestedControllerLockName,
              pendingLockName == nil,
              sentLockName == nil,
              pendingSystemCommand == nil,
              pendingCommandWriteIntents.isEmpty else { return }

        if writeAuthenticatedCommand("GET_LOCK_NAME", intent: .lockNameRefresh) {
            hasRequestedControllerLockName = true
            lockNameStatus = "Checking controller"
        }
    }

    private func requestControllerServoAnglesIfReady() {
        guard isReady,
              fastCommandNonce != nil,
              !isChangingState,
              !hasRequestedControllerServoAngles,
              pendingServoAngles == nil,
              queuedServoAngles == nil,
              sentServoAngles == nil,
              pendingSystemCommand == nil,
              pendingCommandWriteIntents.isEmpty else { return }

        if writeAuthenticatedCommand("GET_ANGLES", intent: .servoAnglesRefresh) {
            hasRequestedControllerServoAngles = true
            servoAnglesStatus = "Checking controller"
        }
    }

    private func requestControllerLastUnlockIfReady() {
        guard isReady,
              fastCommandNonce != nil,
              !isChangingState,
              !hasRequestedControllerLastUnlock,
              pendingSystemCommand == nil,
              pendingCommandWriteIntents.isEmpty else { return }

        if writeAuthenticatedCommand("GET_LAST_UNLOCK", intent: .lastUnlockRefresh) {
            hasRequestedControllerLastUnlock = true
        }
    }

    private func applyControllerLastUnlock(_ record: LastUnlockRecord) {
        guard let controllerLastUnlockAt = record.unlockedAt else {
            if lastUnlockAt == nil {
                UserDefaults.standard.removeObject(forKey: Self.lastUnlockAtKey)
                UserDefaults.standard.removeObject(forKey: Self.lastUnlockDeviceIdentifierKey)
                UserDefaults.standard.removeObject(forKey: Self.lastUnlockDeviceNameKey)
                lastUnlockDeviceIdentifier = ""
                lastUnlockDeviceName = ""
            }
            return
        }

        applyKnownLastUnlock(
            controllerLastUnlockAt,
            deviceIdentifier: record.deviceIdentifier,
            deviceName: record.deviceName,
            replaceDeviceMetadata: true
        )
    }

    private func applyKnownLastUnlock(
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

    private func applyLastUnlockDeviceMetadata(identifier: String?, name: String?, replaceMissing: Bool) {
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
            let sanitizedName = Self.sanitizedDeviceDisplayName(name)
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

    private func refreshControllerLastUnlockSoon() {
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

    private func shouldIgnoreStaleDoorState(_ incomingState: String) -> Bool {
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

    private func reconcileOptimisticDoorCommand(with incomingState: String) {
        guard let optimisticDoorCommand else { return }

        switch (optimisticDoorCommand, incomingState) {
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

    private func handleControllerRejectedState() {
        clearRemoteSettingApplying()

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

    private func handleFastCommandReject(reason: String) {
        invalidatePreparedFastDoorCommandPayloads(clearNonce: true)

        if (reason == "bad_nonce" || reason == "missing_nonce"),
           let command = optimisticDoorCommand,
           optimisticDoorCommandAttempt < 2 {
            pendingFreshNonceDoorCommand = PendingFreshNonceDoorCommand(
                command: command,
                attempt: optimisticDoorCommandAttempt + 1,
                previousServoState: optimisticDoorPreviousServoState,
                origin: optimisticDoorCommandOrigin ?? .manual
            )
            lastError = nil
            _ = readControlIfPermitted()
            startSecureLinkWatchdogIfNeeded()
            return
        }

        if let optimisticDoorCommand {
            let origin = optimisticDoorCommandOrigin
            let restoredState = stableRestoredDoorState()
            clearOptimisticDoorCommand()
            servoState = restoredState
            switch reason {
            case "busy":
                lastError = "Controller is busy."
            case "bad_nonce", "missing_nonce":
                lastError = "Controller asked for a fresh secure command."
            case "bad_signature", "unpaired":
                lastError = "Controller rejected \(optimisticDoorCommand == .unlock ? "unlock" : "lock")."
            default:
                lastError = "Controller rejected \(optimisticDoorCommand == .unlock ? "unlock" : "lock")."
            }
            if restoredState == "locked" || restoredState == "unlocked" {
                publishWidgetState(restoredState)
            }
            if origin == .proximity {
                endProximityUnlockBackgroundTask()
                if optimisticDoorCommand == .unlock && restoredState != "unlocked" {
                    restoreProximityUnlockAfterInterruptedCommand()
                }
            }
        }

    }

    private func clearOptimisticDoorCommand() {
        pendingFreshNonceDoorCommand = nil
        optimisticDoorCommand = nil
        optimisticDoorCommandOrigin = nil
        optimisticDoorCommandSentAt = nil
        optimisticDoorCommandAttempt = 0
        optimisticDoorPreviousServoState = nil
        doorCommandRecoveryTask?.cancel()
        doorCommandRecoveryTask = nil
    }

    @discardableResult
    private func sendPendingFreshNonceDoorCommandIfReady() -> Bool {
        guard let pendingFreshNonceDoorCommand,
              !preparedFastDoorCommandPayloads.isEmpty else {
            return false
        }

        let retry = pendingFreshNonceDoorCommand
        self.pendingFreshNonceDoorCommand = nil
        let didSend = sendDoorCommandAttempt(
            pendingFreshNonceDoorCommand.command,
            attempt: pendingFreshNonceDoorCommand.attempt,
            previousServoState: pendingFreshNonceDoorCommand.previousServoState,
            origin: pendingFreshNonceDoorCommand.origin
        )
        if !didSend {
            self.pendingFreshNonceDoorCommand = retry
        }
        return didSend
    }

    private func scheduleDeviceDisplayNameRetry() {
        deviceDisplayNameSyncTask?.cancel()
        deviceDisplayNameSyncTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.deviceDisplayNameSyncTask = nil
            }
            await self?.retryUnconfirmedDeviceDisplayName()
        }
    }

    private func retryUnconfirmedDeviceDisplayName() {
        guard let name = sentDeviceDisplayName else { return }

        sentDeviceDisplayName = nil
        pendingDeviceDisplayName = name
        deviceDisplayNameStatus = isReady ? "Retrying..." : "Waiting for controller"
        syncDeviceDisplayNameIfReady()
    }

    private func runSystemCommand(_ systemCommand: DoorSystemCommand) {
        guard isReady else {
            pendingSystemCommand = systemCommand
            scan()
            return
        }

        switch systemCommand {
        case .lock:
            send(.lock)
        case .unlock:
            send(.unlock)
        case .toggle:
            guard hasKnownLockState else {
                pendingSystemCommand = systemCommand
                _ = readStateIfPermitted()
                return
            }

            toggleLock()
        }
    }

    private func beginProximityUnlockAwayCheck() {
        guard proximityUnlockEnabled, proximityUnlockArmedAt == nil else {
            updateProximityUnlockStatus()
            return
        }

        guard central?.state == .poweredOn else {
            clearProximityUnlockArming()
            updateProximityUnlockStatus()
            return
        }

        beginProximityUnlockBackgroundTask()
        proximityUnlockCandidateStartedAt = Date()
        proximityUnlockArmTask?.cancel()
        updateProximityUnlockStatus()
        confirmProximityUnlockAwayCheck()
    }

    private func confirmProximityUnlockAwayCheck() {
        proximityUnlockArmTask = nil

        guard proximityUnlockEnabled,
              proximityUnlockCandidateStartedAt != nil,
              central?.state == .poweredOn,
              !isReady else {
            clearProximityUnlockArming()
            updateProximityUnlockStatus()
            return
        }

        guard let startedAt = proximityUnlockCandidateStartedAt else {
            clearProximityUnlockArming()
            updateProximityUnlockStatus()
            return
        }

        guard lockZoneCenter != nil else {
            armProximityUnlockIfCandidateStillCurrent(startedAt: startedAt)
            return
        }

        if isKnownOutsideLockZone {
            armProximityUnlockIfCandidateStillCurrent(startedAt: startedAt)
            return
        }

        lockZoneStatus = "Checking zone"
        proximityUnlockStatus = "Zone check"
        requestCurrentLocation(for: .proximityArmCheck(startedAt))
    }

    private func armProximityUnlockIfCandidateStillCurrent(startedAt: Date) {
        guard proximityUnlockEnabled,
              proximityUnlockCandidateStartedAt == startedAt,
              central?.state == .poweredOn,
              !isReady else {
            clearProximityUnlockArming()
            updateProximityUnlockStatus()
            return
        }

        proximityUnlockCandidateStartedAt = nil
        setProximityUnlockArmed()
        updateProximityUnlockStatus()
    }

    private func armProximityUnlockIfOutsideAndDisconnected() {
        guard proximityUnlockEnabled,
              lockZoneCenter != nil,
              isKnownOutsideLockZone,
              proximityUnlockArmedAt == nil,
              !isReady,
              hasKnownController,
              hasTrustedPairingForSecureCommand else {
            updateProximityUnlockStatus()
            return
        }

        clearProximityUnlockCandidate()
        setProximityUnlockArmed()
        updateProximityUnlockStatus()
    }

    private func setProximityUnlockArmed() {
        let wasAlreadyArmed = proximityUnlockArmedAt != nil
        let armedAt = Date()
        beginProximityUnlockBackgroundTask()
        proximityUnlockArmedAt = armedAt
        UserDefaults.standard.set(armedAt.timeIntervalSince1970, forKey: Self.proximityUnlockArmedAtKey)
        accelerateProximityUnlockReconnectIfNeeded()
        if !wasAlreadyArmed {
            notifyProximityUnlockArmedIfNeeded()
        }
    }

    private func restoreProximityUnlockAfterInterruptedCommand() {
        guard proximityUnlockEnabled,
              lockZoneCenter != nil,
              proximityUnlockArmedAt == nil else {
            updateProximityUnlockStatus()
            return
        }

        clearProximityUnlockCandidate()
        setProximityUnlockArmed()
        proximityUnlockStatus = "Retrying"
        scheduleReconnectCheck(after: 1)
    }

    private func clearProximityUnlockCandidate() {
        proximityUnlockArmTask?.cancel()
        proximityUnlockArmTask = nil
        proximityUnlockCandidateStartedAt = nil
    }

    private func clearProximityUnlockCandidateIfUnarmed() {
        guard proximityUnlockArmedAt == nil else { return }
        clearProximityUnlockCandidate()
    }

    private func clearProximityUnlockArming() {
        let hasPendingProximityCommand = optimisticDoorCommandOrigin == .proximity
        clearProximityUnlockCandidate()
        proximityUnlockArmedAt = nil
        UserDefaults.standard.removeObject(forKey: Self.legacyProximityUnlockArmedAtKey)
        UserDefaults.standard.removeObject(forKey: Self.proximityUnlockArmedAtKey)
        if !hasPendingProximityCommand {
            endProximityUnlockBackgroundTask()
        }
    }

    private func updateProximityUnlockStatus() {
        guard proximityUnlockEnabled else {
            proximityUnlockStatus = "Off"
            return
        }

        if proximityUnlockArmedAt != nil {
            if lockZoneBluetoothRSSI == nil {
                proximityUnlockStatus = "Reading signal"
            } else if !isProximityUnlockRSSIGateSatisfied {
                proximityUnlockStatus = "Signal weak"
            } else {
                proximityUnlockStatus = "Armed"
            }
        } else if proximityUnlockCandidateStartedAt != nil {
            proximityUnlockStatus = "Checking away"
        } else if isReady {
            proximityUnlockStatus = isKnownOutsideLockZone ? "Left zone" : "Monitoring"
        } else if bluetoothState != "On" {
            proximityUnlockStatus = bluetoothState
        } else {
            proximityUnlockStatus = isKnownOutsideLockZone ? "Away" : "Waiting"
        }
    }

    private var isProximityUnlockRSSIGateSatisfied: Bool {
        guard let lockZoneBluetoothRSSI else { return false }
        return lockZoneBluetoothRSSI >= effectiveProximityUnlockRSSIThreshold
    }

    private var effectiveProximityUnlockRSSIThreshold: Int {
        max(proximityUnlockRSSIThreshold ?? Self.reliableProximityUnlockRSSIThreshold, Self.reliableProximityUnlockRSSIThreshold)
    }

    private func requestLocationAuthorizationIfNeeded() {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            requestTemporaryFullAccuracyIfNeeded()
            requestAlwaysLocationAuthorizationIfNeeded()
        case .authorizedAlways:
            requestTemporaryFullAccuracyIfNeeded()
        case .denied, .restricted:
            break
        @unknown default:
            break
        }
    }

    private func requestAlwaysLocationAuthorizationIfNeeded() {
        guard proximityUnlockEnabled,
              !UserDefaults.standard.bool(forKey: Self.hasRequestedAlwaysLocationKey) else {
            return
        }

        UserDefaults.standard.set(true, forKey: Self.hasRequestedAlwaysLocationKey)
        locationManager.requestAlwaysAuthorization()
    }

    private func requestTemporaryFullAccuracyIfNeeded() {
        guard locationManager.authorizationStatus == .authorizedWhenInUse || locationManager.authorizationStatus == .authorizedAlways,
              locationManager.accuracyAuthorization == .reducedAccuracy,
              !isRequestingTemporaryFullAccuracy else {
            return
        }

        isRequestingTemporaryFullAccuracy = true
        locationManager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: Self.lockZonePrecisionPurposeKey) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.isRequestingTemporaryFullAccuracy = false
                if self.locationManager.accuracyAuthorization == .reducedAccuracy {
                    self.lockZoneStatus = "Precise off"
                }
            }
        }
    }

    private func configureBestAccuracyLocation() {
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.distanceFilter = kCLDistanceFilterNone
        locationManager.activityType = .otherNavigation
        locationManager.pausesLocationUpdatesAutomatically = false
    }

    private func requestBestAvailableCurrentLocation() {
        configureBestAccuracyLocation()

        guard locationManager.accuracyAuthorization == .reducedAccuracy else {
            locationManager.requestLocation()
            return
        }

        guard !isRequestingTemporaryFullAccuracy else {
            locationManager.requestLocation()
            return
        }

        isRequestingTemporaryFullAccuracy = true
        locationManager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: Self.lockZonePrecisionPurposeKey) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.isRequestingTemporaryFullAccuracy = false
                if self.locationManager.accuracyAuthorization == .reducedAccuracy {
                    self.lockZoneStatus = "Precise off"
                }
                self.locationManager.requestLocation()
            }
        }
    }

    private func startBestAvailableLocationUpdates() {
        configureBestAccuracyLocation()
        requestTemporaryFullAccuracyIfNeeded()
        if locationManager.accuracyAuthorization == .reducedAccuracy {
            lockZoneStatus = "Precise off"
        }
        locationManager.startUpdatingLocation()
    }

    private func requestCurrentLocation(for request: LockZoneLocationRequest) {
        pendingLocationRequests.append(request)

        switch request {
        case .updateLockZoneAfterUnlock, .setLockZoneFromSettings:
            lockZoneStatus = "Finding location"
        case .proximityArmCheck:
            lockZoneStatus = "Checking zone"
        }

        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            requestBestAvailableCurrentLocation()
            if locationManager.authorizationStatus == .authorizedWhenInUse {
                requestAlwaysLocationAuthorizationIfNeeded()
            }
        case .denied, .restricted:
            failPendingLocationRequests("Location off")
        @unknown default:
            failPendingLocationRequests("Location unavailable")
        }
    }

    private func failPendingLocationRequests(_ status: String) {
        let requests = pendingLocationRequests
        pendingLocationRequests.removeAll()
        guard !requests.isEmpty else { return }
        lockZoneStatus = status

        if requests.contains(where: { request in
            if case .proximityArmCheck = request { return true }
            return false
        }) {
            clearProximityUnlockCandidateIfUnarmed()
            proximityUnlockStatus = status
        }
    }

    private func processPendingLocationRequests(with location: CLLocation) {
        let requests = pendingLocationRequests
        pendingLocationRequests.removeAll()
        updateLockZoneLocationSnapshot(location, mutatesContainment: requests.isEmpty)
        guard !requests.isEmpty else { return }

        for request in requests {
            process(location, for: request)
        }
    }

    private func process(_ location: CLLocation, for request: LockZoneLocationRequest) {
        let accuracy = location.horizontalAccuracy
        guard accuracy >= 0, accuracy <= Self.maximumLockZoneAccuracyMeters else {
            switch request {
            case .proximityArmCheck:
                lockZoneStatus = "Accuracy low"
                clearProximityUnlockCandidateIfUnarmed()
                proximityUnlockStatus = "Zone unknown"
            case .updateLockZoneAfterUnlock, .setLockZoneFromSettings:
                lockZoneStatus = "Accuracy low"
                lastError = "Move near a window or try again to set the lock zone."
            }
            return
        }

        switch request {
        case .updateLockZoneAfterUnlock, .setLockZoneFromSettings:
            saveLockZone(center: location.coordinate)
        case .proximityArmCheck(let startedAt):
            resolveProximityArmCheck(startedAt: startedAt, location: location)
        }
    }

    private func saveLockZone(center: CLLocationCoordinate2D) {
        guard CLLocationCoordinate2DIsValid(center) else { return }

        let updatedAt = Date()
        lockZoneCenter = center
        lockZoneUpdatedAt = updatedAt
        lockZoneStatus = "Zone set"
        setKnownOutsideLockZone(false)

        UserDefaults.standard.set(center.latitude, forKey: Self.lockZoneLatitudeKey)
        UserDefaults.standard.set(center.longitude, forKey: Self.lockZoneLongitudeKey)
        UserDefaults.standard.set(lockZoneRadiusMeters, forKey: Self.lockZoneRadiusKey)
        UserDefaults.standard.set(updatedAt.timeIntervalSince1970, forKey: Self.lockZoneUpdatedAtKey)
        restartLockZoneMonitoring()
    }

    private func resolveProximityArmCheck(startedAt: Date, location: CLLocation) {
        guard proximityUnlockCandidateStartedAt == startedAt else {
            updateProximityUnlockStatus()
            return
        }

        guard let lockZoneCenter else {
            armProximityUnlockIfCandidateStillCurrent(startedAt: startedAt)
            return
        }

        let lockLocation = CLLocation(latitude: lockZoneCenter.latitude, longitude: lockZoneCenter.longitude)
        let distance = location.distance(from: lockLocation)
        let insideBoundary = lockZoneRadiusMeters + max(location.horizontalAccuracy, 0)

        if distance <= insideBoundary {
            setKnownOutsideLockZone(false)
            clearProximityUnlockCandidateIfUnarmed()
            lockZoneStatus = "Inside zone"
            proximityUnlockStatus = "Inside zone"
        } else {
            setKnownOutsideLockZone(true)
            lockZoneStatus = "Left zone"
            armProximityUnlockIfCandidateStillCurrent(startedAt: startedAt)
        }
    }

    private func requestLockZoneLocationSnapshotIfAvailable() {
        guard lockZoneCenter != nil else { return }

        switch locationManager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            requestBestAvailableCurrentLocation()
        default:
            break
        }
    }

    private func updateLockZoneLocationSnapshotIfPossible() {
        guard let latestLockZoneLocation else { return }
        updateLockZoneLocationSnapshot(latestLockZoneLocation, mutatesContainment: true)
    }

    private func updateLockZoneLocationSnapshot(_ location: CLLocation, mutatesContainment: Bool) {
        latestLockZoneLocation = location
        lockZoneUserLocation = location.coordinate
        lockZoneUserAccuracyMeters = location.horizontalAccuracy >= 0 ? location.horizontalAccuracy : nil
        lockZoneSpeedMetersPerSecond = location.speed >= 0 ? location.speed : nil
        lockZoneCourseDegrees = location.course >= 0 ? location.course : nil
        lockZoneCourseAccuracyDegrees = location.courseAccuracy >= 0 ? location.courseAccuracy : nil

        guard let lockZoneCenter else {
            lockZoneDistanceMeters = nil
            return
        }

        let lockLocation = CLLocation(latitude: lockZoneCenter.latitude, longitude: lockZoneCenter.longitude)
        let distance = location.distance(from: lockLocation)
        lockZoneDistanceMeters = distance

        guard mutatesContainment,
              proximityUnlockArmedAt == nil,
              proximityUnlockCandidateStartedAt == nil else {
            return
        }

        let accuracy = max(location.horizontalAccuracy, 0)
        guard accuracy <= Self.maximumLockZoneAccuracyMeters else {
            lockZoneStatus = "Accuracy low"
            updateProximityUnlockStatus()
            return
        }

        let isOutside = distance > lockZoneRadiusMeters + accuracy
        setKnownOutsideLockZone(isOutside)
        lockZoneStatus = isOutside ? "Left zone" : "Inside zone"
        if isOutside {
            armProximityUnlockIfOutsideAndDisconnected()
        } else {
            updateProximityUnlockStatus()
        }
    }

    private func setKnownOutsideLockZone(_ isOutside: Bool) {
        isKnownOutsideLockZone = isOutside
        UserDefaults.standard.set(isOutside, forKey: Self.lockZoneOutsideKey)
    }

    private func restartLockZoneMonitoring() {
        stopLockZoneMonitoring()

        guard proximityUnlockEnabled,
              let lockZoneCenter,
              CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else {
            stopProximityBackgroundLocationMonitoring()
            return
        }

        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
            stopProximityBackgroundLocationMonitoring()
            return
        case .authorizedWhenInUse:
            requestAlwaysLocationAuthorizationIfNeeded()
        case .authorizedAlways:
            break
        case .denied, .restricted:
            lockZoneStatus = "Location off"
            stopProximityBackgroundLocationMonitoring()
            return
        @unknown default:
            stopProximityBackgroundLocationMonitoring()
            return
        }

        let maximumRadius = locationManager.maximumRegionMonitoringDistance
        let radius = min(lockZoneRadiusMeters, maximumRadius > 0 ? maximumRadius : lockZoneRadiusMeters)
        let region = CLCircularRegion(center: lockZoneCenter, radius: radius, identifier: Self.lockZoneRegionIdentifier)
        region.notifyOnEntry = true
        region.notifyOnExit = true
        locationManager.startMonitoring(for: region)
        locationManager.requestState(for: region)
        requestLockZoneLocationSnapshotIfAvailable()
        startProximityBackgroundLocationMonitoringIfNeeded()
    }

    private func stopLockZoneMonitoring() {
        for region in locationManager.monitoredRegions where region.identifier == Self.lockZoneRegionIdentifier {
            locationManager.stopMonitoring(for: region)
        }
    }

    private func startProximityBackgroundLocationMonitoringIfNeeded() {
        guard proximityUnlockEnabled,
              lockZoneCenter != nil,
              locationManager.authorizationStatus == .authorizedAlways else {
            stopProximityBackgroundLocationMonitoring()
            return
        }

        guard !isSignificantLocationMonitoringActive else { return }
        locationManager.startMonitoringSignificantLocationChanges()
        isSignificantLocationMonitoringActive = true
    }

    private func stopProximityBackgroundLocationMonitoring() {
        guard isSignificantLocationMonitoringActive else { return }
        locationManager.stopMonitoringSignificantLocationChanges()
        isSignificantLocationMonitoringActive = false
    }

    private func updateLockZoneContainment(from state: CLRegionState) {
        switch state {
        case .inside:
            setKnownOutsideLockZone(false)
            lockZoneStatus = "Inside zone"
            clearProximityUnlockCandidateIfUnarmed()
        case .outside:
            setKnownOutsideLockZone(true)
            lockZoneStatus = "Left zone"
            armProximityUnlockIfOutsideAndDisconnected()
        case .unknown:
            lockZoneStatus = "Zone unknown"
        @unknown default:
            lockZoneStatus = "Zone unknown"
        }

        updateProximityUnlockStatus()
    }

    @discardableResult
    private func runProximityUnlockIfReady() -> Bool {
        guard proximityUnlockEnabled, proximityUnlockArmedAt != nil else {
            updateProximityUnlockStatus()
            return false
        }

        beginProximityUnlockBackgroundTask()

        guard isSecureCommandWriteReady, pendingSystemCommand == nil else {
            updateProximityUnlockStatus()
            return false
        }

        guard !isUnlocked else {
            clearProximityUnlockArming()
            updateProximityUnlockStatus()
            return false
        }

        let now = Date()
        if let lastProximityUnlockAt,
           now.timeIntervalSince(lastProximityUnlockAt) < Self.proximityUnlockCooldownSeconds {
            clearProximityUnlockArming()
            updateProximityUnlockStatus()
            return false
        }

        guard isProximityUnlockRSSIGateSatisfied else {
            if lockZoneBluetoothRSSI == nil {
                peripheral?.readRSSI()
            }
            updateProximityUnlockStatus()
            return false
        }

        proximityUnlockStatus = "Unlocking"
        if sendAuthenticated(.unlock, origin: .proximity) {
            clearProximityUnlockArming()
            lastProximityUnlockAt = now
            proximityUnlockStatus = "Unlocking"
            return true
        } else {
            restoreProximityUnlockAfterInterruptedCommand()
            return false
        }
    }

    private func startScan() {
        guard central?.state == .poweredOn else { return }

        central?.stopScan()
        connectionState = "Scanning"
        updateProximityUnlockStatus()
        central?.scanForPeripherals(withServices: [serviceUUID], options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: true
        ])
        scheduleReconnectCheck(after: reconnectCheckDelay(5))
    }

    private func accelerateProximityUnlockReconnectIfNeeded() {
        guard proximityUnlockEnabled,
              proximityUnlockArmedAt != nil,
              central?.state == .poweredOn,
              !isSecureCommandWriteReady else {
            return
        }

        if !connectToKnownPeripheralIfPossible() {
            startScan()
        }
    }

    private func connectToKnownPeripheralIfPossible() -> Bool {
        guard let central,
              let identifierText = UserDefaults.standard.string(forKey: Self.knownPeripheralIdentifierKey),
              let identifier = UUID(uuidString: identifierText) else {
            return false
        }

        guard let knownPeripheral = central.retrievePeripherals(withIdentifiers: [identifier]).first else {
            return false
        }

        if knownPeripheral.state == .disconnecting {
            return false
        }

        restoreOrConnect(to: knownPeripheral, reason: "Known controller")
        scheduleReconnectCheck(after: reconnectCheckDelay(Self.knownPeripheralFreshScanFallbackDelay))
        return true
    }

    private func connect(to peripheral: CBPeripheral) {
        guard let central else { return }

        saveKnownPeripheral(peripheral)

        if peripheral.state == .connected {
            self.peripheral = peripheral
            self.peripheral?.delegate = self
            connectionState = commandCharacteristic == nil ? "Discovering" : "Ready"
            clearProximityUnlockCandidateIfUnarmed()
            updateProximityUnlockStatus()
            discoverControllerServices(on: peripheral)
            return
        }

        guard peripheral.state != .connecting else {
            connectionState = "Connecting"
            clearProximityUnlockCandidateIfUnarmed()
            updateProximityUnlockStatus()
            scheduleReconnectCheck(after: reconnectCheckDelay(5))
            return
        }

        self.peripheral = peripheral
        self.peripheral?.delegate = self
        connectionState = "Connecting"
        clearProximityUnlockCandidateIfUnarmed()
        updateProximityUnlockStatus()
        central.stopScan()
        central.connect(peripheral, options: nil)
        scheduleReconnectCheck(after: reconnectCheckDelay(6))
    }

    private func saveKnownPeripheral(_ peripheral: CBPeripheral) {
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.knownPeripheralIdentifierKey)
    }

    private func forgetKnownPeripheral(_ peripheral: CBPeripheral) {
        guard UserDefaults.standard.string(forKey: Self.knownPeripheralIdentifierKey) == peripheral.identifier.uuidString else {
            return
        }
        UserDefaults.standard.removeObject(forKey: Self.knownPeripheralIdentifierKey)
    }

    private func clearDiscoveredControllerCharacteristics() {
        knownPairingFallbackTask?.cancel()
        knownPairingFallbackTask = nil
        commandCharacteristic = nil
        stateCharacteristic = nil
        pairingCharacteristic = nil
        controlCharacteristic = nil
        stopSecureLinkWatchdog()
        stopRSSIMonitoring()
        invalidatePreparedFastDoorCommandPayloads(clearNonce: true)
    }

    private func restoreOrConnect(to restoredPeripheral: CBPeripheral, reason: String) {
        guard let central else { return }

        saveKnownPeripheral(restoredPeripheral)
        if peripheral?.identifier != restoredPeripheral.identifier {
            clearDiscoveredControllerCharacteristics()
        }
        peripheral = restoredPeripheral
        peripheral?.delegate = self
        lastError = nil

        switch restoredPeripheral.state {
        case .connected:
            reconnectTimer?.invalidate()
            connectionState = reason
            clearProximityUnlockCandidateIfUnarmed()
            updateProximityUnlockStatus()
            discoverControllerServices(on: restoredPeripheral)
        case .connecting:
            connectionState = "Reconnecting"
            clearProximityUnlockCandidateIfUnarmed()
            updateProximityUnlockStatus()
        case .disconnected, .disconnecting:
            connectionState = "Reconnecting"
            clearProximityUnlockCandidateIfUnarmed()
            updateProximityUnlockStatus()
            central.stopScan()
            central.connect(restoredPeripheral, options: nil)
            scheduleReconnectCheck(after: reconnectCheckDelay(6))
        @unknown default:
            connectionState = "Reconnecting"
            updateProximityUnlockStatus()
            central.stopScan()
            central.connect(restoredPeripheral, options: nil)
            scheduleReconnectCheck(after: reconnectCheckDelay(6))
        }
    }

    private func discoverControllerServices(on peripheral: CBPeripheral) {
        peripheral.delegate = self

        let cachedDoorServices = peripheral.services?.filter { $0.uuid == serviceUUID } ?? []
        guard !cachedDoorServices.isEmpty else {
            peripheral.discoverServices([serviceUUID])
            scheduleReconnectCheck(after: reconnectCheckDelay(6))
            return
        }

        var discoveredAnyCharacteristics = false
        for service in cachedDoorServices {
            if let characteristics = service.characteristics {
                discoveredAnyCharacteristics = true
                applyControllerCharacteristics(characteristics, on: peripheral)
            } else {
                peripheral.discoverCharacteristics([commandUUID, stateUUID, pairingUUID, controlUUID], for: service)
            }
        }

        if discoveredAnyCharacteristics, finishConnectionIfReady() {
            return
        }

        if discoveredAnyCharacteristics {
            cachedDoorServices
                .filter { $0.characteristics == nil || !serviceHasAllRequiredCharacteristics($0) }
                .forEach { peripheral.discoverCharacteristics([commandUUID, stateUUID, pairingUUID, controlUUID], for: $0) }
        }
        scheduleReconnectCheck(after: reconnectCheckDelay(6))
    }

    private func applyControllerCharacteristics(_ characteristics: [CBCharacteristic], on peripheral: CBPeripheral) {
        for characteristic in characteristics {
            if characteristic.uuid == commandUUID {
                commandCharacteristic = characteristic
            } else if characteristic.uuid == stateUUID {
                stateCharacteristic = characteristic
                if characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
                    peripheral.setNotifyValue(true, for: characteristic)
                }
                readStateIfPermitted()
            } else if characteristic.uuid == pairingUUID {
                pairingCharacteristic = characteristic
            } else if characteristic.uuid == controlUUID {
                controlCharacteristic = characteristic
                if characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
                    peripheral.setNotifyValue(true, for: characteristic)
                }
            }
        }
    }

    private func serviceHasAllRequiredCharacteristics(_ service: CBService) -> Bool {
        let characteristicUUIDs = Set((service.characteristics ?? []).map(\.uuid))
        return characteristicUUIDs.contains(commandUUID)
            && characteristicUUIDs.contains(stateUUID)
            && characteristicUUIDs.contains(pairingUUID)
    }

    @discardableResult
    private func finishConnectionIfReady() -> Bool {
        guard commandCharacteristic != nil && stateCharacteristic != nil && pairingCharacteristic != nil else {
            return false
        }

        reconnectTimer?.invalidate()
        connectionState = "Ready"
        startRSSIMonitoringIfNeeded()
        startSecureLinkWatchdogIfNeeded()
        _ = promoteKnownControllerPairingIfNeeded()
        readStateIfPermitted()
        scheduleKnownPairingFallbackIfNeeded()
        if runProximityUnlockIfReady() {
            updateProximityUnlockStatus()
            return true
        }
        syncLockNameIfReady()
        requestControllerLockNameIfReady()
        requestControllerServoAnglesIfReady()
        sendPendingSystemCommandIfReady()
        updateProximityUnlockStatus()
        return true
    }

    private func startRSSIMonitoringIfNeeded() {
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

    private func stopRSSIMonitoring() {
        rssiReadTask?.cancel()
        rssiReadTask = nil
        lockZoneBluetoothRSSI = nil
    }

    private func startSecureLinkWatchdogIfNeeded() {
        guard secureLinkWatchdogTask == nil else { return }

        secureLinkWatchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                let shouldContinue = await MainActor.run { () -> Bool in
                    guard let self,
                          self.isReady,
                          !self.isDoorCommandReady else {
                        return false
                    }

                    self.peripheral?.readRSSI()
                    self.updateProximityUnlockStatus()
                    return true
                }

                guard shouldContinue else { break }

                await MainActor.run {
                    guard let self,
                          self.isReady,
                          !self.isDoorCommandReady,
                          self.fastCommandNonce == nil,
                          let peripheral = self.peripheral,
                          let controlCharacteristic = self.controlCharacteristic else {
                        return
                    }

                    if controlCharacteristic.isNotifying {
                        peripheral.setNotifyValue(false, for: controlCharacteristic)
                    }
                }

                try? await Task.sleep(nanoseconds: 140_000_000)

                await MainActor.run {
                    guard let self,
                          self.isReady,
                          !self.isDoorCommandReady,
                          self.fastCommandNonce == nil,
                          let peripheral = self.peripheral,
                          let controlCharacteristic = self.controlCharacteristic else {
                        return
                    }

                    peripheral.setNotifyValue(true, for: controlCharacteristic)
                    _ = self.readControlIfPermitted()
                }

                try? await Task.sleep(for: .seconds(1.4))
            }

            await MainActor.run {
                self?.secureLinkWatchdogTask = nil
            }
        }
    }

    private func stopSecureLinkWatchdog() {
        secureLinkWatchdogTask?.cancel()
        secureLinkWatchdogTask = nil
    }

    private func reconnectCheckDelay(_ defaultDelay: TimeInterval) -> TimeInterval {
        proximityUnlockArmedAt == nil ? defaultDelay : min(defaultDelay, 1.5)
    }

    private func scheduleReconnectCheck(after delay: TimeInterval) {
        reconnectTimer?.invalidate()
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.recoverConnectionIfNeeded()
            }
        }
    }

    private func recoverConnectionIfNeeded() {
        guard !isSecureCommandWriteReady, central?.state == .poweredOn else { return }

        if let peripheral, peripheral.state == .connecting {
            central?.cancelPeripheralConnection(peripheral)
            self.peripheral = nil
            UserDefaults.standard.removeObject(forKey: Self.knownPeripheralIdentifierKey)
            connectionState = "Scanning"
            updateProximityUnlockStatus()
            startScan()
            return
        }

        clearDiscoveredControllerCharacteristics()
        hasRequestedControllerLockName = false
        pairingState = "Unknown"
        pairingApprovalCode = nil
        updateProximityUnlockStatus()
        if connectToKnownPeripheralIfPossible() {
            return
        }
        startScan()
    }

    private func publishWidgetState(
        _ state: String,
        updatedAt: Date = .now,
        resetAutoLockDeadline: Bool = false,
        controllerRemainingSeconds: Int? = nil
    ) {
        let previousSnapshot = DoorStatusStore.load()
        let deadline = predictedAutoLockDeadline(
            for: state,
            updatedAt: updatedAt,
            resetAutoLockDeadline: resetAutoLockDeadline,
            controllerRemainingSeconds: controllerRemainingSeconds
        )
        let startedAt = predictedAutoLockStartedAt(
            for: state,
            updatedAt: updatedAt,
            resetAutoLockDeadline: resetAutoLockDeadline,
            controllerRemainingSeconds: controllerRemainingSeconds,
            deadline: deadline
        )
        DoorStatusStore.save(state: state, updatedAt: updatedAt, autoLockStartedAt: startedAt, autoLockDeadline: deadline)
        reloadDoorWidgets(deadline: deadline)
        notifyIfNeeded(for: state, previousSnapshot: previousSnapshot, deadline: deadline)
        scheduleAutoLockPrediction(deadline: deadline)
        syncLiveActivity(state: state, startedAt: startedAt, deadline: deadline)
    }

    private func reloadDoorWidgets(deadline: Date? = nil) {
        requestDoorWidgetReload()
        widgetReloadTask?.cancel()
        widgetReloadGeneration += 1
        let generation = widgetReloadGeneration
        endWidgetReloadBackgroundTask()
        beginWidgetReloadBackgroundTask()

        let now = Date()
        var reloadDates = [1.0, 2.5, 6.0].map { now.addingTimeInterval($0) }
        if let deadline {
            reloadDates.append(deadline.addingTimeInterval(-0.25))
            reloadDates.append(deadline.addingTimeInterval(0.25))
            reloadDates.append(deadline.addingTimeInterval(1.5))
        }
        reloadDates = reloadDates
            .filter { $0 > now }
            .sorted()

        widgetReloadTask = Task { [weak self] in
            for reloadDate in reloadDates {
                let delay = reloadDate.timeIntervalSinceNow
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
                if Task.isCancelled { break }
                await MainActor.run {
                    self?.requestDoorWidgetReload()
                }
            }

            await MainActor.run {
                guard self?.widgetReloadGeneration == generation else { return }
                self?.endWidgetReloadBackgroundTask()
            }
        }
    }

    private func requestDoorWidgetReload() {
        WidgetCenter.shared.reloadTimelines(ofKind: Self.widgetKind)
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func requestUnlockNotificationAuthorization() {
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

    private func requestBackgroundReliabilityNotificationAuthorizationIfNeeded() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }

            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] _, _ in
                Task { @MainActor in
                    self?.refreshNotificationSettings()
                }
            }
        }
    }

    private func notifyProximityUnlockArmedIfNeeded() {
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

    @objc nonisolated private func applicationWillTerminate() {
        Task { @MainActor in
            guard forceQuitReliabilityWarningTask != nil else { return }
            scheduleBackgroundReliabilityWarningIfNeeded(delay: 1, bypassCooldown: true)
        }
    }

    private func applyNotificationSettings(_ settings: UNNotificationSettings) {
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

    private func notifyIfNeeded(
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

        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized ||
                    settings.authorizationStatus == .provisional ||
                    settings.authorizationStatus == .ephemeral else {
                return
            }

            let content = UNMutableNotificationContent()
            content.title = "\(self.lockName) unlocked"
            if let deadline, deadline > .now {
                let remainingSeconds = max(0, Int(ceil(deadline.timeIntervalSinceNow)))
                content.body = "Auto-locks in \(remainingSeconds) seconds."
            } else {
                content.body = "\(self.lockName) is unlocked."
            }
            content.sound = .default
            content.threadIdentifier = "DoorUnlocker"

            let request = UNNotificationRequest(
                identifier: Self.unlockNotificationIdentifier,
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request)
        }
    }

    private func predictedAutoLockDeadline(
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

    private func predictedAutoLockStartedAt(
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

    private func scheduleAutoLockPrediction(deadline: Date?) {
        autoLockPredictionTask?.cancel()

        guard let deadline else {
            autoLockRemainingSeconds = nil
            return
        }

        updateAutoLockRemaining(deadline: deadline)

        autoLockPredictionTask = Task { [weak self] in
            while !Task.isCancelled {
                await MainActor.run {
                    self?.updateAutoLockRemaining(deadline: deadline)
                }

                let remaining = deadline.timeIntervalSinceNow
                if remaining <= 0 {
                    break
                }

                let sleepSeconds = min(1, max(0.1, remaining))
                try? await Task.sleep(nanoseconds: UInt64(sleepSeconds * 1_000_000_000))
            }

            await MainActor.run {
                if !Task.isCancelled {
                    self?.applyPredictedAutoLock(deadline: deadline)
                }
            }
        }
    }

    private func updateAutoLockRemaining(deadline: Date) {
        guard isUnlocked else {
            autoLockRemainingSeconds = nil
            return
        }

        autoLockRemainingSeconds = max(0, Int(ceil(deadline.timeIntervalSinceNow)))
    }

    private func applyPredictedAutoLock(deadline: Date) {
        guard isUnlocked else { return }

        servoState = "locked"
        autoLockRemainingSeconds = nil
        updatePairingState(from: "locked")
        publishWidgetState("locked", updatedAt: deadline)
        _ = readStateIfPermitted()
    }

    private func reconcilePredictedAutoLock() {
        let snapshot = DoorStatusStore.load()
        guard isUnlocked, snapshot.state == "locked" else { return }

        servoState = "locked"
        autoLockRemainingSeconds = nil
        updatePairingState(from: "locked")
        publishWidgetState("locked", updatedAt: snapshot.updatedAt ?? .now)
    }

    private func dismissStoredLockedLiveActivityIfNeeded() {
        let snapshot = DoorStatusStore.load()
        guard !snapshot.isUnlocked, !Activity<DoorUnlockerActivityAttributes>.activities.isEmpty else { return }

        beginLiveActivityBackgroundTask()
        liveActivityCompletionTask = Task { await completeAndDismissLiveActivity(confirmationDuration: 0) }
    }

    private func syncLiveActivity(state: String, startedAt: Date?, deadline: Date?) {
        if (state == "unlocked" || state == "unlocking"), let deadline, deadline > .now {
            isCompletingLiveActivity = false
            liveActivityCompletionTask?.cancel()
            beginLiveActivityBackgroundTask()
            Task { await startOrUpdateLiveActivity(state: state, startedAt: startedAt ?? .now, deadline: deadline) }
            scheduleLiveActivityCompletion(deadline: deadline)
        } else {
            guard !isCompletingLiveActivity else { return }
            liveActivityCompletionTask?.cancel()
            beginLiveActivityBackgroundTask()
            liveActivityCompletionTask = Task { await completeAndDismissLiveActivity() }
        }
    }

    private func scheduleLiveActivityCompletion(deadline: Date) {
        liveActivityCompletionTask?.cancel()
        liveActivityCompletionTask = Task { [weak self] in
            let transitionStart = deadline.addingTimeInterval(-Self.liveActivityLockTransitionLeadSeconds)
            let sleepSeconds = max(0, transitionStart.timeIntervalSinceNow)
            if sleepSeconds > 0 {
                try? await Task.sleep(nanoseconds: UInt64(sleepSeconds * 1_000_000_000))
            }

            guard !Task.isCancelled else { return }
            await self?.completeAndDismissLiveActivity(deadline: deadline)
        }
    }

    private func startOrUpdateLiveActivity(state: String, startedAt: Date, deadline: Date) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let contentState = DoorUnlockerActivityAttributes.ContentState(state: state, autoLockStartedAt: startedAt, autoLockDeadline: deadline)
        let content = ActivityContent(
            state: contentState,
            staleDate: deadline.addingTimeInterval(Self.liveActivityLockConfirmationSeconds + Self.liveActivityStaleGraceSeconds),
            relevanceScore: 1
        )

        do {
            if let activity = activeLiveActivity {
                liveActivity = activity
                await activity.update(content)
            } else {
                let attributes = DoorUnlockerActivityAttributes(title: lockName)
                liveActivity = try Activity<DoorUnlockerActivityAttributes>.request(
                    attributes: attributes,
                    content: content,
                    pushType: nil
                )
            }
        } catch {
            print("Live Activity unavailable: \(error.localizedDescription)")
        }
    }

    private func completeAndDismissLiveActivity(deadline: Date? = nil, confirmationDuration: TimeInterval? = nil) async {
        guard !isCompletingLiveActivity else { return }

        isCompletingLiveActivity = true
        defer {
            isCompletingLiveActivity = false
            endLiveActivityBackgroundTask()
        }

        let activities = Activity<DoorUnlockerActivityAttributes>.activities
        guard liveActivity != nil || !activities.isEmpty else { return }
        let confirmationDuration = confirmationDuration ?? Self.liveActivityLockConfirmationSeconds
        let animationStartedAt = Date()
        let lockDeadline = deadline ?? animationStartedAt

        func liveActivityContent(
            state: String,
            phase: Int?,
            staleDate: Date?,
            relevanceScore: Double
        ) -> ActivityContent<DoorUnlockerActivityAttributes.ContentState> {
            ActivityContent(
                state: DoorUnlockerActivityAttributes.ContentState(
                    state: state,
                    autoLockStartedAt: animationStartedAt,
                    autoLockDeadline: lockDeadline,
                    lockAnimationStartedAt: animationStartedAt,
                    lockAnimationPhase: phase
                ),
                staleDate: staleDate,
                relevanceScore: relevanceScore
            )
        }

        let staleDate = max(lockDeadline, animationStartedAt)
            .addingTimeInterval(Self.liveActivityLockedVisibleSeconds + Self.liveActivityStaleGraceSeconds)

        func shouldContinueLockTransition() -> Bool {
            guard !Task.isCancelled else { return false }

            let snapshot = DoorStatusStore.load()
            if !snapshot.isUnlocked {
                return true
            }

            guard let deadline,
                  let snapshotDeadline = snapshot.autoLockDeadline else {
                return false
            }

            return abs(snapshotDeadline.timeIntervalSince(deadline)) < 1.5
        }

        func updatePhase(_ phase: Int, state: String = "locking", relevanceScore: Double = 0.7) async -> Bool {
            let content = liveActivityContent(state: state, phase: phase, staleDate: staleDate, relevanceScore: relevanceScore)
            for activity in Activity<DoorUnlockerActivityAttributes>.activities {
                await activity.update(content)
            }
            return shouldContinueLockTransition()
        }

        func pause(_ seconds: TimeInterval) async -> Bool {
            guard seconds > 0 else { return shouldContinueLockTransition() }
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return shouldContinueLockTransition()
        }

        if confirmationDuration > 0 {
            guard await updatePhase(0) else { return }
            guard await pause(Self.liveActivityLockAnimationSettleSeconds) else { return }
            guard await updatePhase(1) else { return }
            guard await pause(Self.liveActivityLockAnimationHalfSeconds) else { return }
            guard await updatePhase(2) else { return }
            let lockRevealDelay = deadline.map { max(Self.liveActivityLockAnimationSwapSeconds, $0.timeIntervalSinceNow) }
                ?? Self.liveActivityLockAnimationSwapSeconds
            guard await pause(lockRevealDelay) else { return }
            guard await updatePhase(3, state: "locked", relevanceScore: 0.8) else { return }
            guard await pause(Self.liveActivityLockAnimationHalfSeconds) else { return }
        }

        let finalContent = liveActivityContent(state: "locked", phase: 3, staleDate: nil, relevanceScore: 0.2)
        let lockedContent = liveActivityContent(state: "locked", phase: 3, staleDate: staleDate, relevanceScore: 0.4)
        for activity in Activity<DoorUnlockerActivityAttributes>.activities {
            await activity.update(lockedContent)
        }

        guard shouldContinueLockTransition() else { return }

        if confirmationDuration > 0 {
            let elapsed = Date().timeIntervalSince(animationStartedAt)
            let remainingConfirmation = max(0, confirmationDuration - elapsed)
            let lockedHoldSeconds = max(
                Self.liveActivityMinimumLockedHoldSeconds,
                Self.liveActivityLockedVisibleSeconds,
                remainingConfirmation
            )
            try? await Task.sleep(nanoseconds: UInt64(lockedHoldSeconds * 1_000_000_000))
            guard shouldContinueLockTransition() else { return }
        }

        for activity in Activity<DoorUnlockerActivityAttributes>.activities {
            await activity.end(finalContent, dismissalPolicy: .immediate)
        }
        liveActivity = nil
    }

    private var activeLiveActivity: Activity<DoorUnlockerActivityAttributes>? {
        let activities = Activity<DoorUnlockerActivityAttributes>.activities
        return liveActivity.flatMap { activity in
            activity.activityState == .active || activity.activityState == .stale ? activity : nil
        } ?? activities.first { activity in
            activity.activityState == .active || activity.activityState == .stale
        }
    }

    private func beginLiveActivityBackgroundTask() {
        guard liveActivityBackgroundTask == .invalid else { return }

        liveActivityBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "DoorUnlockerAutoLock") { [weak self] in
            Task { @MainActor in
                self?.endLiveActivityBackgroundTask()
            }
        }
    }

    private func endLiveActivityBackgroundTask() {
        guard liveActivityBackgroundTask != .invalid else { return }

        UIApplication.shared.endBackgroundTask(liveActivityBackgroundTask)
        liveActivityBackgroundTask = .invalid
    }

    private func beginWidgetReloadBackgroundTask() {
        guard widgetReloadBackgroundTask == .invalid else { return }

        widgetReloadBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "DoorUnlockerWidgetReload") { [weak self] in
            Task { @MainActor in
                self?.widgetReloadTask?.cancel()
                self?.endWidgetReloadBackgroundTask()
            }
        }
    }

    private func endWidgetReloadBackgroundTask() {
        guard widgetReloadBackgroundTask != .invalid else { return }

        UIApplication.shared.endBackgroundTask(widgetReloadBackgroundTask)
        widgetReloadBackgroundTask = .invalid
    }

    private func beginProximityUnlockBackgroundTask() {
        guard proximityUnlockEnabled,
              proximityUnlockBackgroundTask == .invalid else {
            return
        }

        proximityUnlockBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "DoorUnlockerProximityUnlock") { [weak self] in
            Task { @MainActor in
                self?.endProximityUnlockBackgroundTask()
            }
        }
    }

    private func endProximityUnlockBackgroundTask() {
        guard proximityUnlockBackgroundTask != .invalid else { return }

        UIApplication.shared.endBackgroundTask(proximityUnlockBackgroundTask)
        proximityUnlockBackgroundTask = .invalid
    }

    private func beginForceQuitReliabilityWarningBackgroundTask() {
        guard forceQuitReliabilityWarningBackgroundTask == .invalid else { return }

        forceQuitReliabilityWarningBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "DoorUnlockerForceQuitWarning") { [weak self] in
            Task { @MainActor in
                self?.forceQuitReliabilityWarningTask?.cancel()
                self?.cancelBackgroundReliabilityWarning()
                self?.endForceQuitReliabilityWarningBackgroundTask()
            }
        }
    }

    private func endForceQuitReliabilityWarningBackgroundTask() {
        guard forceQuitReliabilityWarningBackgroundTask != .invalid else { return }

        UIApplication.shared.endBackgroundTask(forceQuitReliabilityWarningBackgroundTask)
        forceQuitReliabilityWarningBackgroundTask = .invalid
    }

    @discardableResult
    private func readStateIfPermitted() -> Bool {
        guard let peripheral, let stateCharacteristic else {
            return false
        }

        guard stateCharacteristic.properties.contains(.read) else {
            return false
        }

        peripheral.readValue(for: stateCharacteristic)
        return true
    }

    @discardableResult
    private func readControlIfPermitted() -> Bool {
        guard let peripheral, let controlCharacteristic else {
            return false
        }

        guard controlCharacteristic.properties.contains(.read) else {
            return false
        }

        peripheral.readValue(for: controlCharacteristic)
        return true
    }

    private func parseControllerState(_ rawState: String) -> (state: String, remainingSeconds: Int?) {
        let trimmedState = rawState.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmedState.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              let remainingSeconds = Int(parts[1]) else {
            return (trimmedState, nil)
        }

        if parts[0] == "unlocked" {
            return ("unlocked", max(0, remainingSeconds))
        }

        if parts[0] == "timeout_set" {
            return ("timeout_set", max(0, remainingSeconds))
        }

        return (trimmedState, nil)
    }

    private static func lockName(from rawState: String) -> String? {
        let prefix = "lock_name:"
        guard rawState.hasPrefix(prefix) else { return nil }

        let rawName = String(rawState.dropFirst(prefix.count))
        let sanitizedName = DoorStatusStore.sanitizedLockName(rawName)
        return sanitizedName.isEmpty ? nil : sanitizedName
    }

    private static func fastCommandNonce(from rawState: String) -> Data? {
        let prefix = "nonce:v3:"
        guard rawState.hasPrefix(prefix) else { return nil }

        let hex = String(rawState.dropFirst(prefix.count))
        return dataFromHex(hex, expectedByteCount: 16)
    }

    private static func fastCommandRejectReason(from rawState: String) -> String? {
        let prefix = "reject:v3:"
        guard rawState.hasPrefix(prefix) else { return nil }

        let reason = String(rawState.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return reason.isEmpty ? "rejected" : reason
    }

    private static func dataFromHex(_ hex: String, expectedByteCount: Int) -> Data? {
        guard hex.count == expectedByteCount * 2 else { return nil }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(expectedByteCount)
        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard nextIndex <= hex.endIndex,
                  let byte = UInt8(hex[index..<nextIndex], radix: 16) else {
                return nil
            }
            bytes.append(byte)
            index = nextIndex
        }

        return bytes.count == expectedByteCount ? Data(bytes) : nil
    }

    private static func settingApplying(from rawState: String) -> (kind: String, value: String?)? {
        let prefix = "setting_applying:"
        guard rawState.hasPrefix(prefix) else { return nil }

        let payload = String(rawState.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = payload.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let kind = parts.first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let value = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : nil

        let normalizedKind = kind.isEmpty ? "settings" : kind
        let normalizedValue = value?.isEmpty == true ? nil : value
        return (normalizedKind, normalizedValue)
    }

    private static func servoAngles(from rawState: String) -> ServoAngles? {
        let prefix = "servo_angles:"
        guard rawState.hasPrefix(prefix) else { return nil }

        let values = rawState.dropFirst(prefix.count)
            .split(separator: ",", maxSplits: 1)
            .compactMap { Int(String($0).trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard values.count == 2 else { return nil }
        return ServoAngles(lockAngle: values[0], unlockAngle: values[1])
    }

    private static func lastUnlockRecord(from rawState: String) -> LastUnlockRecord? {
        let prefix = "last_unlock:"
        guard rawState.hasPrefix(prefix) else { return nil }

        let payload = String(rawState.dropFirst(prefix.count))
        let parts = payload.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        let rawTimestamp = parts.first ?? ""
        guard let timestamp = TimeInterval(rawTimestamp), timestamp > 0 else {
            return LastUnlockRecord(unlockedAt: nil, deviceIdentifier: nil, deviceName: nil)
        }

        let secondValue = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let thirdValue = parts.count > 2 ? parts[2].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let secondValueIsIdentifier = isTrustedDeviceIdentifier(secondValue)
        let identifier = secondValueIsIdentifier ? secondValue : nil
        let deviceName = secondValueIsIdentifier
            ? thirdValue
            : parts.dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespacesAndNewlines)

        return LastUnlockRecord(
            unlockedAt: Date(timeIntervalSince1970: timestamp),
            deviceIdentifier: identifier?.isEmpty == true ? nil : identifier,
            deviceName: deviceName.isEmpty ? nil : deviceName
        )
    }

    private static func connectedDevices(from rawState: String) -> (count: Int, max: Int, devices: [ConnectedControllerDevice])? {
        let prefix = "connections:"
        guard rawState.hasPrefix(prefix) else { return nil }

        let payload = String(rawState.dropFirst(prefix.count))
        let parts = payload.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let countParts = (parts.first ?? "").split(separator: "/", maxSplits: 1).map(String.init)
        let count = Int(countParts.first ?? "") ?? 0
        let maxConnections = countParts.count > 1 ? (Int(countParts[1]) ?? max(count, 4)) : max(count, 4)
        let names = parts.count > 1
            ? parts[1].split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            : []
        let devices = names.enumerated().compactMap { index, rawName -> ConnectedControllerDevice? in
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            return ConnectedControllerDevice(slot: index + 1, name: name)
        }

        return (count, maxConnections, devices)
    }

    private static func isTrustedDeviceIdentifier(_ value: String) -> Bool {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedValue.count == 19 else { return false }

        for (index, character) in trimmedValue.enumerated() {
            if index == 4 || index == 9 || index == 14 {
                guard character == "-" else { return false }
            } else {
                guard character.isHexDigit else { return false }
            }
        }

        return true
    }
}

extension DoorUnlockerController: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            switch manager.authorizationStatus {
            case .authorizedWhenInUse:
                requestTemporaryFullAccuracyIfNeeded()
                requestAlwaysLocationAuthorizationIfNeeded()
                if isLockZoneLocationUpdating {
                    startBestAvailableLocationUpdates()
                }
                if !pendingLocationRequests.isEmpty {
                    requestBestAvailableCurrentLocation()
                }
                restartLockZoneMonitoring()
            case .authorizedAlways:
                requestTemporaryFullAccuracyIfNeeded()
                if isLockZoneLocationUpdating {
                    startBestAvailableLocationUpdates()
                }
                if !pendingLocationRequests.isEmpty {
                    requestBestAvailableCurrentLocation()
                }
                restartLockZoneMonitoring()
            case .denied, .restricted:
                failPendingLocationRequests("Location off")
                lockZoneStatus = "Location off"
            case .notDetermined:
                break
            @unknown default:
                failPendingLocationRequests("Location unavailable")
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }

        Task { @MainActor in
            processPendingLocationRequests(with: location)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let heading = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        guard heading >= 0,
              newHeading.headingAccuracy >= 0 else { return }

        Task { @MainActor in
            lockZoneHeadingDegrees = heading
            lockZoneHeadingAccuracyDegrees = newHeading.headingAccuracy
        }
    }

    nonisolated func locationManagerShouldDisplayHeadingCalibration(_ manager: CLLocationManager) -> Bool {
        true
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            failPendingLocationRequests("Location unavailable")
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        guard region.identifier == Self.lockZoneRegionIdentifier else { return }

        Task { @MainActor in
            updateLockZoneContainment(from: .inside)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        guard region.identifier == Self.lockZoneRegionIdentifier else { return }

        Task { @MainActor in
            updateLockZoneContainment(from: .outside)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didDetermineState state: CLRegionState, for region: CLRegion) {
        guard region.identifier == Self.lockZoneRegionIdentifier else { return }

        Task { @MainActor in
            updateLockZoneContainment(from: state)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        guard region?.identifier == Self.lockZoneRegionIdentifier else { return }

        Task { @MainActor in
            lockZoneStatus = "Zone monitor off"
        }
    }
}

extension DoorUnlockerController: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            switch central.state {
            case .poweredOn:
                bluetoothState = "On"
                if proximityUnlockArmedAt != nil {
                    beginProximityUnlockBackgroundTask()
                    accelerateProximityUnlockReconnectIfNeeded()
                } else {
                    scan()
                }
            case .poweredOff:
                bluetoothState = "Off"
                connectionState = "Bluetooth off"
            case .unauthorized:
                bluetoothState = "Unauthorized"
                connectionState = "Permission needed"
            case .unsupported:
                bluetoothState = "Unsupported"
                connectionState = "Unsupported"
            case .resetting:
                bluetoothState = "Resetting"
                connectionState = "Resetting"
            case .unknown:
                bluetoothState = "Unknown"
                connectionState = "Starting"
            @unknown default:
                bluetoothState = "Unknown"
                connectionState = "Starting"
            }

            if central.state != .poweredOn {
                clearProximityUnlockArming()
            }
            updateProximityUnlockStatus()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        Task { @MainActor in
            self.central = central
            if proximityUnlockArmedAt != nil {
                beginProximityUnlockBackgroundTask()
            }
            connectionState = "Restoring"
            updateProximityUnlockStatus()

            let restoredPeripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
            guard let restoredPeripheral = restoredPeripherals.first(where: { $0.state == .connected || $0.state == .connecting })
                ?? restoredPeripherals.first else {
                return
            }

            restoreOrConnect(to: restoredPeripheral, reason: "Restoring")
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        Task { @MainActor in
            if proximityUnlockArmedAt != nil {
                beginProximityUnlockBackgroundTask()
            }
            let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
            deviceName = peripheral.name ?? localName ?? "DoorUnlocker-XIAO-v4"
            lockZoneBluetoothRSSI = RSSI.intValue
            if proximityUnlockArmedAt != nil, !isProximityUnlockRSSIGateSatisfied {
                updateProximityUnlockStatus()
                return
            }
            connect(to: peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            if proximityUnlockArmedAt != nil {
                beginProximityUnlockBackgroundTask()
            }
            reconnectTimer?.invalidate()
            connectionState = "Discovering"
            lastError = nil
            clearProximityUnlockCandidateIfUnarmed()
            updateProximityUnlockStatus()
            peripheral.delegate = self
            saveKnownPeripheral(peripheral)
            discoverControllerServices(on: peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            connectionState = "Disconnected"
            connectedDeviceCount = 0
            connectedDevices = []
            self.peripheral = nil
            forgetKnownPeripheral(peripheral)
            lastError = error?.localizedDescription ?? "Connect failed"
            if isKnownOutsideLockZone {
                armProximityUnlockIfOutsideAndDisconnected()
            } else {
                updateProximityUnlockStatus()
            }
            scheduleReconnectCheck(after: 1)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            let shouldCheckProximityUnlock = proximityUnlockEnabled && central.state == .poweredOn && hasTrustedPairingForSecureCommand
            connectionState = "Disconnected"
            connectedDeviceCount = 0
            connectedDevices = []
            clearDiscoveredControllerCharacteristics()
            hasRequestedControllerLockName = false
            hasRequestedControllerServoAngles = false
            hasRequestedControllerLastUnlock = false
            pairingState = "Unknown"
            pairingApprovalCode = nil
            if let error {
                forgetKnownPeripheral(peripheral)
                lastError = error.localizedDescription
            }
            if shouldCheckProximityUnlock {
                beginProximityUnlockAwayCheck()
                startScan()
            } else {
                clearProximityUnlockArming()
                updateProximityUnlockStatus()
                scheduleReconnectCheck(after: 1)
            }
        }
    }
}

extension DoorUnlockerController: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            if let error {
                lastError = error.localizedDescription
                scheduleReconnectCheck(after: 1)
                return
            }

            let doorServices = peripheral.services?.filter { $0.uuid == serviceUUID } ?? []
            guard !doorServices.isEmpty else {
                lastError = "Door service not found"
                scheduleReconnectCheck(after: 1)
                return
            }

            discoverControllerServices(on: peripheral)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        Task { @MainActor in
            if let error {
                lastError = error.localizedDescription
                scheduleReconnectCheck(after: 1)
                return
            }

            applyControllerCharacteristics(service.characteristics ?? [], on: peripheral)

            if !finishConnectionIfReady() {
                lastError = "Required controller characteristic not found"
                central?.cancelPeripheralConnection(peripheral)
                scheduleReconnectCheck(after: 1)
            }
        }
    }

    private func sendPendingSystemCommandIfReady() {
        guard isReady, fastCommandNonce != nil else { return }

        if let seconds = queuedAutoLockTimeoutSeconds {
            queuedAutoLockTimeoutSeconds = nil
            autoLockSeconds = seconds
            applyAutoLockTimeout()
            return
        }

        if let angles = queuedServoAngles {
            queuedServoAngles = nil
            servoLockAngle = angles.lockAngle
            servoUnlockAngle = angles.unlockAngle
            pendingServoAngles = angles
            applyServoAngles()
            return
        }

        guard let command = pendingSystemCommand else { return }
        if command == .toggle, !hasKnownLockState {
            if !readStateIfPermitted() {
                pendingSystemCommand = nil
                toggleLock()
            }
            return
        }

        pendingSystemCommand = nil
        runSystemCommand(command)
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor in
            guard characteristic.uuid == controlUUID else { return }

            if let error {
                if isReady, !isDoorCommandReady {
                    lastError = nil
                    startSecureLinkWatchdogIfNeeded()
                } else {
                    lastError = error.localizedDescription
                }
                return
            }

            if characteristic.isNotifying {
                _ = readControlIfPermitted()
                if proximityUnlockArmedAt != nil || lockZoneBluetoothRSSI == nil {
                    peripheral.readRSSI()
                }
            }

            if isReady, !isDoorCommandReady {
                startSecureLinkWatchdogIfNeeded()
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor in
            if let error {
                if (characteristic.uuid != stateUUID && characteristic.uuid != controlUUID) || !isReadNotPermitted(error) {
                    lastError = error.localizedDescription
                }
                return
            }

            guard let data = characteristic.value else { return }
            let rawState = String(data: data, encoding: .utf8) ?? "unknown"
            if characteristic.uuid == controlUUID {
                if let nonce = Self.fastCommandNonce(from: rawState) {
                    applyFastCommandNonce(nonce)
                    updatePairingState(from: "paired")
                    return
                }

                if let rejectReason = Self.fastCommandRejectReason(from: rawState) {
                    handleFastCommandReject(reason: rejectReason)
                    updatePairingState(from: "paired")
                    return
                }

                return
            }

            guard characteristic.uuid == stateUUID else { return }

            if let applying = Self.settingApplying(from: rawState) {
                applyRemoteSettingApplying(kind: applying.kind, value: applying.value)
                updatePairingState(from: "paired")
                return
            }

            if let controllerLockName = Self.lockName(from: rawState) {
                applyControllerLockName(controllerLockName)
                updatePairingState(from: "paired")
                requestControllerServoAnglesIfReady()
                return
            }

            if let controllerServoAngles = Self.servoAngles(from: rawState) {
                applyControllerServoAngles(controllerServoAngles)
                updatePairingState(from: "paired")
                requestControllerLastUnlockIfReady()
                return
            }

            if let controllerLastUnlock = Self.lastUnlockRecord(from: rawState) {
                applyControllerLastUnlock(controllerLastUnlock)
                hasRequestedControllerLastUnlock = true
                updatePairingState(from: "paired")
                return
            }

            if let connections = Self.connectedDevices(from: rawState) {
                connectedDeviceCount = connections.count
                maximumConnectedDeviceCount = connections.max
                connectedDevices = connections.devices
                if pairingState == "Unknown" {
                    promoteKnownControllerPairingIfNeeded()
                }
                return
            }

            let parsedState = parseControllerState(rawState)
            if parsedState.state == "timeout_set" {
                if let seconds = parsedState.remainingSeconds {
                    applyControllerAutoLockTimeout(seconds)
                }
                updatePairingState(from: parsedState.state)
                syncLockNameIfReady()
                syncDeviceDisplayNameIfReady()
                requestControllerLockNameIfReady()
                requestControllerServoAnglesIfReady()
                requestControllerLastUnlockIfReady()
                return
            }

            if parsedState.state == "paired" {
                clearRemoteSettingApplying()
                updatePairingState(from: parsedState.state)
                confirmDeviceDisplayNameSyncIfNeeded()
                syncLockNameIfReady()
                syncDeviceDisplayNameIfReady()
                requestControllerLockNameIfReady()
                requestControllerServoAnglesIfReady()
                requestControllerLastUnlockIfReady()
                return
            }

            if shouldIgnoreStaleDoorState(parsedState.state) {
                return
            }

            if parsedState.state == "rejected" {
                handleControllerRejectedState()
                return
            }

            servoState = parsedState.state
            reconcileOptimisticDoorCommand(with: parsedState.state)
            updatePairingState(from: parsedState.state)
            publishWidgetState(parsedState.state, controllerRemainingSeconds: parsedState.remainingSeconds)
            sendPendingSystemCommandIfReady()
            syncLockNameIfReady()
            syncDeviceDisplayNameIfReady()
            requestControllerLockNameIfReady()
            requestControllerServoAnglesIfReady()
            requestControllerLastUnlockIfReady()
            runProximityUnlockIfReady()
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard error == nil else { return }

        Task { @MainActor in
            lockZoneBluetoothRSSI = RSSI.intValue
            if proximityUnlockArmedAt != nil {
                _ = runProximityUnlockIfReady()
            } else {
                updateProximityUnlockStatus()
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor in
            let commandWriteIntent: CommandWriteIntent? = {
                guard characteristic.uuid == commandUUID, !pendingCommandWriteIntents.isEmpty else {
                    return nil
                }
                return pendingCommandWriteIntents.removeFirst()
            }()

            if let error {
                if case .autoLockTimeout(let seconds) = commandWriteIntent,
                   pendingAutoLockTimeoutSeconds == seconds {
                    if autoLockApplyTask != nil {
                        autoLockStatus = "Setting..."
                    } else if autoLockSeconds == seconds {
                        pendingAutoLockTimeoutSeconds = nil
                        autoLockStatus = "Not set"
                    }
                }
                if case .deviceDisplayName(let name) = commandWriteIntent,
                   sentDeviceDisplayName == name {
                    deviceDisplayNameSyncTask?.cancel()
                    deviceDisplayNameSyncTask = nil
                    sentDeviceDisplayName = nil
                    pendingDeviceDisplayName = name
                    deviceDisplayNameStatus = "Not set"
                }
                if case .lockName(let name) = commandWriteIntent,
                   sentLockName == name {
                    lockNameSyncTask?.cancel()
                    lockNameSyncTask = nil
                    sentLockName = nil
                    pendingLockName = name
                    lockNameStatus = "Not set"
                }
                if case .servoAngles(let angles) = commandWriteIntent,
                   sentServoAngles == angles {
                    sentServoAngles = nil
                    pendingServoAngles = angles
                    servoAnglesStatus = "Not set"
                }
                if case .lockNameRefresh = commandWriteIntent {
                    hasRequestedControllerLockName = false
                    lockNameStatus = "Could not check controller"
                }
                if case .servoAnglesRefresh = commandWriteIntent {
                    hasRequestedControllerServoAngles = false
                    servoAnglesStatus = "Could not check controller"
                }
                if case .lastUnlockRefresh = commandWriteIntent {
                    hasRequestedControllerLastUnlock = false
                }
                if case .doorCommand(.unlock, _, _) = commandWriteIntent {
                    hasRequestedControllerLastUnlock = false
                }
                if case .doorCommand(let command, _, let origin) = commandWriteIntent {
                    let restoredState = stableRestoredDoorState()
                    clearOptimisticDoorCommand()
                    servoState = restoredState
                    if restoredState == "locked" || restoredState == "unlocked" {
                        publishWidgetState(restoredState)
                    }
                    if command == .unlock, origin == .proximity {
                        restoreProximityUnlockAfterInterruptedCommand()
                    }
                }
                lastError = error.localizedDescription
                if characteristic.uuid == pairingUUID {
                    pairingState = "Pairing locked"
                }
                return
            }

            if case .autoLockTimeout(let seconds) = commandWriteIntent,
               pendingAutoLockTimeoutSeconds == seconds {
                autoLockStatus = autoLockSeconds == seconds ? "Waiting for controller" : "Setting..."
                if isUnlocked {
                    publishWidgetState(servoState, resetAutoLockDeadline: true)
                }
                readStateIfPermitted()
            }

            if case .deviceDisplayName(let name) = commandWriteIntent,
               sentDeviceDisplayName == name {
                deviceDisplayNameStatus = "Waiting for controller"
                readStateIfPermitted()
            }

            if case .lockName(let name) = commandWriteIntent,
               sentLockName == name {
                lockNameStatus = "Waiting for controller"
                readStateIfPermitted()
            }

            if case .servoAngles(let angles) = commandWriteIntent,
               sentServoAngles == angles {
                servoAnglesStatus = "Waiting for controller"
                readStateIfPermitted()
            }

            if case .lockNameRefresh = commandWriteIntent {
                readStateIfPermitted()
            }

            if case .servoAnglesRefresh = commandWriteIntent {
                readStateIfPermitted()
            }

            if case .lastUnlockRefresh = commandWriteIntent {
                readStateIfPermitted()
            }

            if case .doorCommand = commandWriteIntent {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 120_000_000)
                    _ = self?.readControlIfPermitted()
                    _ = self?.readStateIfPermitted()
                }
            }

            if characteristic.uuid == pairingUUID {
                readStateIfPermitted()
            }
        }
    }

    private func isReadNotPermitted(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == CBATTError.errorDomain && nsError.code == CBATTError.Code.readNotPermitted.rawValue
    }

    private func setKnownPairedController(_ isKnown: Bool) {
        hasKnownPairedController = isKnown
        UserDefaults.standard.set(isKnown, forKey: Self.knownPairedControllerKey)
    }

    private func scheduleKnownPairingFallbackIfNeeded() {
        knownPairingFallbackTask?.cancel()
        knownPairingFallbackTask = nil

        guard pairingState == "Unknown",
              hasKnownPairedController,
              commandCharacteristic != nil,
              pairingCharacteristic != nil,
              peripheral?.state == .connected else {
            return
        }

        knownPairingFallbackTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            await MainActor.run {
                guard let self else { return }
                if self.promoteKnownControllerPairingIfNeeded() {
                    self.readStateIfPermitted()
                }
            }
        }
    }

    @discardableResult
    private func promoteKnownControllerPairingIfNeeded() -> Bool {
        guard pairingState == "Unknown",
              hasKnownPairedController,
              commandCharacteristic != nil,
              pairingCharacteristic != nil,
              peripheral?.state == .connected else {
            return false
        }

        updatePairingState(from: "paired")
        sendPendingSystemCommandIfReady()
        syncLockNameIfReady()
        syncDeviceDisplayNameIfReady()
        requestControllerLockNameIfReady()
        requestControllerServoAnglesIfReady()
        requestControllerLastUnlockIfReady()
        return true
    }

    private func updatePairingState(from state: String) {
        switch state {
        case "pairing_enabled":
            knownPairingFallbackTask?.cancel()
            knownPairingFallbackTask = nil
            pairingState = "Pairing enabled"
            pairingApprovalCode = nil
        case "pairing_pending":
            knownPairingFallbackTask?.cancel()
            knownPairingFallbackTask = nil
            pairingState = "Pairing pending"
            if pairingApprovalCode == nil {
                pairingApprovalCode = try? DoorCommandAuthenticator.pairingApprovalCode()
            }
        case "pairing_locked", "unpaired":
            knownPairingFallbackTask?.cancel()
            knownPairingFallbackTask = nil
            pairingState = "Pairing locked"
            pairingApprovalCode = nil
            setKnownPairedController(false)
            invalidatePreparedFastDoorCommandPayloads(clearNonce: true)
        case "paired", "locked", "unlocked", "locking", "unlocking", "timeout_set":
            knownPairingFallbackTask?.cancel()
            knownPairingFallbackTask = nil
            pairingState = "Paired"
            setKnownPairedController(true)
            if state == "paired" {
                pairingApprovalCode = nil
            }
        default:
            break
        }

        if !isSecureCommandWriteReady || !hasTrustedPairingForSecureCommand {
            invalidatePreparedFastDoorCommandPayloads(clearNonce: true)
        }

        if isReady, !isDoorCommandReady {
            startSecureLinkWatchdogIfNeeded()
        }
    }
}
