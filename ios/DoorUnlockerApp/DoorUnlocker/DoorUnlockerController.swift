import CoreBluetooth
import CoreLocation
import DoorUnlockerShared
import Foundation
import ActivityKit
import LocalAuthentication
import UIKit
import UserNotifications
import WidgetKit

private let doorUnlockerUnlockNotificationIdentifier = "DoorUnlockerUnlocked"
private let doorUnlockerLockZoneRegionIdentifier = "DoorUnlockerLockZone"

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

    private enum LockZoneLocationRequest {
        case updateLockZoneAfterUnlock
        case setLockZoneFromSettings
        case proximityArmCheck(Date)
    }

    private struct PendingFreshNonceDoorCommand {
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
            case "door_command_usable":
                return "Door command usable"
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
    private static let fastKnownControllerRetryDelay: TimeInterval = 0.15
    private static let activeConnectionRecoveryDelay: TimeInterval = 1.0
    private static let acknowledgedDoorCommandSettleDelay: TimeInterval = 0.45
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

    @Published private(set) var bluetoothState = "Starting" {
        didSet {
            recordStartupStateChange("bluetooth_state", from: oldValue, to: bluetoothState)
        }
    }
    @Published private(set) var connectionState = "Starting" {
        didSet {
            recordStartupStateChange("connection_state", from: oldValue, to: connectionState)
        }
    }
    @Published private(set) var deviceName = "DoorUnlocker-XIAO-v4"
    @Published private(set) var connectedDeviceCount = 0
    @Published private(set) var maximumConnectedDeviceCount = 4
    @Published private(set) var connectedDevices: [ConnectedControllerDevice] = []
    @Published private(set) var servoState = DoorUnlockerController.storedInitialServoState()
    @Published var pairingState = "Unknown" {
        didSet {
            recordStartupStateChange("pairing_state", from: oldValue, to: pairingState)
        }
    }
    @Published var pairingApprovalCode: String?
    @Published var pairingAdminApprovalCode = ""
    @Published var activePairingInvite: PairingInvite?
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
    @Published private(set) var firmwareVersion = DoorUnlockerController.storedFirmwareVersion()
    @Published var firmwareUpdateStatus = "Ready" {
        didSet { syncFirmwareUpdateLiveActivityIfNeeded() }
    }
    @Published var firmwareUpdateProgress: Int? {
        didSet { syncFirmwareUpdateLiveActivityIfNeeded() }
    }
    @Published private(set) var isFirmwareUpdateRunning = false {
        didSet { syncFirmwareUpdateLiveActivityIfNeeded() }
    }
    @Published private(set) var startupTelemetryEntries: [StartupTelemetryEntry] = []
    @Published var lastError: String?

    private static let unlockAuthenticationKey = "RequireUnlockAuthentication"
    private static let unlockHoldRequirementKey = "RequireHoldToUnlock"
    private static let unlockHoldDurationKey = "UnlockHoldDurationSeconds"
    private static let unlockNotificationsKey = "UnlockNotificationsEnabled"
    private static let proximityUnlockArmedNotificationIdentifier = "DoorUnlockerProximityUnlockArmed"
    private static let backgroundReliabilityWarningIdentifier = "DoorUnlockerBackgroundReliabilityWarning"
    private static let backgroundReliabilityWarningLastScheduledAtKey = "DoorUnlockerBackgroundReliabilityWarningLastScheduledAt"
    private static let proximityUnlockArmedNotificationLastSentAtKey = "DoorUnlockerProximityUnlockArmedNotificationLastSentAt"
    private static let backgroundReliabilityWarningCooldown: TimeInterval = 12 * 60 * 60
    private static let proximityUnlockArmedNotificationCooldown: TimeInterval = 60
    private static let backgroundReliabilityWarningDelay: TimeInterval = 1
    private static let forceQuitReliabilityWarningFireDelay: TimeInterval = 15
    private static let forceQuitReliabilityWarningCancelDelay: TimeInterval = 12
    static let firmwareUpdateSuccessDisplayDuration: TimeInterval = 2.6
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
    private static let lockZonePrecisionPurposeKey = "LockZonePrecision"
    private static let hasRequestedAlwaysLocationKey = "DoorUnlockerHasRequestedAlwaysLocation"
    private static let autoLockSecondsKey = "AutoLockSeconds"
    private static let lastUnlockAtKey = "DoorUnlockerLastUnlockAt"
    private static let lastUnlockDeviceIdentifierKey = "DoorUnlockerLastUnlockDeviceIdentifier"
    private static let lastUnlockDeviceNameKey = "DoorUnlockerLastUnlockDeviceName"
    static let cachedFirmwareVersionKey = "DoorUnlockerCachedFirmwareVersion"
    private static let deviceDisplayNameKey = "DoorUnlockerDeviceDisplayName"
    private static let knownPeripheralIdentifierKey = "DoorUnlockerKnownPeripheralIdentifier"
    private static let knownPeripheralIdentityVersionKey = "DoorUnlockerKnownPeripheralIdentityVersion"
    private static let currentPeripheralIdentityVersion = "v4-control-characteristic"
    private static let knownPairedControllerKey = "DoorUnlockerKnownPairedController"
    private static let centralRestorationIdentifier = "io.github.bt1142msstate.DoorUnlocker.central"
#if DEBUG
    private static let debugFirmwareVerifiedNotificationPrefix = "io.github.bt1142msstate.DoorUnlocker.debugFirmwareVerified"
#endif
    private static let widgetKind = "DoorUnlockerWidget"
    private let serviceUUID = CBUUID(string: "7A5A2000-2B8D-4C3E-94E7-0B3C0DDAAF10")
    private let commandUUID = CBUUID(string: "7A5A2001-2B8D-4C3E-94E7-0B3C0DDAAF10")
    private let stateUUID = CBUUID(string: "7A5A2002-2B8D-4C3E-94E7-0B3C0DDAAF10")
    private let pairingUUID = CBUUID(string: "7A5A2003-2B8D-4C3E-94E7-0B3C0DDAAF10")
    private let controlUUID = CBUUID(string: "7A5A2004-2B8D-4C3E-94E7-0B3C0DDAAF10")

    private var central: CBCentralManager?
    var peripheral: CBPeripheral?
    private var commandCharacteristic: CBCharacteristic?
    var stateCharacteristic: CBCharacteristic?
    var pairingCharacteristic: CBCharacteristic?
    private var controlCharacteristic: CBCharacteristic?
    private var reconnectTimer: Timer?
    private var pendingSystemCommand: DoorSystemCommand?
    private var pendingCommandWriteIntents: [CommandWriteIntent] = []
    private var optimisticDoorCommand: Command?
    private var optimisticDoorCommandOrigin: DoorCommandOrigin?
    private var optimisticDoorCommandSentAt: Date?
    private var optimisticDoorCommandAttempt = 0
    private var optimisticDoorCommandAcknowledged = false
    private var optimisticDoorPreviousServoState: String?
    private var doorCommandRecoveryTask: Task<Void, Never>?
    private var pendingFreshNonceDoorCommand: PendingFreshNonceDoorCommand?
    var fastCommandNonce: Data?
    private var preparedFastDoorCommandPayloads: [Command: DoorCommandAuthenticator.SignedFastCommandPayload] = [:]
    private var preparedFastDoorCommandTask: Task<Void, Never>?
    private var preparedFastDoorCommandGeneration = 0
    private var pendingAutoLockTimeoutSeconds: Int?
    private var queuedAutoLockTimeoutSeconds: Int?
    private var pendingServoAngles: ServoAngles?
    private var queuedServoAngles: ServoAngles?
    var queuedPairingAdminCommand: String?
    var shouldPairFromInviteWhenReady = false
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
    private var startupHousekeepingTask: Task<Void, Never>?
    private var proximityUnlockCandidateStartedAt: Date?
    private var proximityUnlockArmTask: Task<Void, Never>?
    private var proximityUnlockArmedAt = DoorUnlockerController.storedProximityUnlockArmedAt()
    private var lastProximityUnlockAt: Date?
    private var hasKnownPairedController = UserDefaults.standard.bool(forKey: DoorUnlockerController.knownPairedControllerKey)
    private var remoteSettingApplyTask: Task<Void, Never>?
    private var rssiReadTask: Task<Void, Never>?
    private var secureLinkWatchdogTask: Task<Void, Never>?
    private var postReadySyncTask: Task<Void, Never>?
    private var stateSnapshotFallbackTask: Task<Void, Never>?
    var firmwareVersionSnapshotRetryTask: Task<Void, Never>?
    var stateUpdateGeneration = 0
    private var controlNonceRecoveryTask: Task<Void, Never>?
    private var controlUpdateGeneration = 0
    private var hasAuthenticatedCurrentLink = false
    private var linkAuthenticationInFlight = false
    private var knownPeripheralAssistScanTask: Task<Void, Never>?
    private var activeScanAllowsDuplicates: Bool?
    var hasRejectedCurrentSecurePairing = false
    private lazy var firmwareDfuManager = DoorFirmwareDfuManager(delegate: self)
    let firmwareLiveActivityCoordinator = DoorFirmwareLiveActivityCoordinator()
    private var pendingFirmwareUpdatePackageURL: URL?
    private var firmwareUpdateEntryCommandSent = false
    private var firmwareDfuStartFallbackTask: Task<Void, Never>?
    var firmwareUpdateCompletionResetTask: Task<Void, Never>?
    private var didHandleDebugLaunchFirmwareUpdateArgument = false
#if DEBUG
    private var debugExpectedFirmwareVersion: String?
    private var debugFirmwareAwaitingPostDfuVerification = false
    private var debugFirmwareVerifiedNotificationPosted = false
    private let startupTelemetryStartedAt = ProcessInfo.processInfo.systemUptime
    private var startupTelemetryEvents: Set<String> = []
#endif
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

    private var hasDiscoveredControllerCharacteristics: Bool {
        commandCharacteristic != nil
            && stateCharacteristic != nil
            && pairingCharacteristic != nil
            && controlCharacteristic != nil
    }

    var isReady: Bool {
        hasDiscoveredControllerCharacteristics
            && peripheral?.state == .connected
            && hasTrustedPairingForSecureCommand
    }

    var isPreparingKnownController: Bool {
        guard bluetoothState == "On",
              !isReady,
              hasKnownPairedController else {
            return false
        }

        switch connectionState {
        case "Scanning", "Connecting", "Discovering", "Reconnecting", "Restoring", "Starting", "Known controller", "Disconnected":
            return true
        default:
            return false
        }
    }

    var isDoorCommandReady: Bool {
        isReady && (fastCommandNonce != nil || !preparedFastDoorCommandPayloads.isEmpty)
    }

    var canAcceptDoorCommand: Bool {
        pendingFreshNonceDoorCommand == nil &&
            ((isReady && hasTrustedPairingForSecureCommand) || canQueueDoorCommandForKnownController)
    }

    var visibleLastError: String? {
        guard let lastError else { return nil }

        if shouldHideFirmwareUpdateTransientError(lastError) {
            return nil
        }

        if shouldHideTransientStartupError(lastError) {
            return nil
        }

        return lastError
    }

    var isDoorCommandQueuedForSecureLink: Bool {
        pendingFreshNonceDoorCommand != nil
    }

    var queuedDoorCommandActionTitle: String {
        switch pendingFreshNonceDoorCommand?.command {
        case .lock:
            return "Preparing lock..."
        case .unlock:
            return "Preparing unlock..."
        case nil:
            return isUnlocked ? "Tap to lock" : "Tap to unlock"
        }
    }

    var secureLinkActionTitle: String {
        guard isReady, !isDoorCommandReady else {
            return isUnlocked ? "Tap to lock" : "Tap to unlock"
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

        if controlCharacteristic == nil {
            return "Opening secure control."
        }

        return "Preparing secure control."
    }

    var secureLinkStatusDetail: String {
        guard isReady, !isDoorCommandReady else {
            return "Bluetooth is on. This iPhone is paired with the lock."
        }

        if controlCharacteristic == nil {
            return "The app is opening the controller control channel."
        }

        return "The app is requesting a fresh encrypted command nonce from the controller."
    }

    var connectedDevicesTitle: String {
        if canAcceptDoorCommand && !isReady {
            return hasKnownController ? "Saved link ready" : "Trusted link ready"
        }

        return "\(displayedConnectedDeviceCount) of \(displayedMaximumConnectedDeviceCount) connected"
    }

    var connectedDevicesDetail: String {
        if canAcceptDoorCommand && !isReady {
            return hasKnownController
                ? "This iPhone can queue a secure command while the saved Bluetooth link opens."
                : "This iPhone can queue a secure command while it finds the trusted controller."
        }

        if connectedDevices.isEmpty {
            if isReady || canAcceptDoorCommand {
                return "This iPhone is ready. Other devices will appear when identified."
            }
            return displayedConnectedDeviceCount > 0 ? "Connected devices are identifying." : "No other devices are connected."
        }

        return connectedDevices.map(\.displayName).joined(separator: ", ")
    }

    var shouldShowConnectedDevicesSummary: Bool {
        displayedConnectedDeviceCount > 0 || isReady || canAcceptDoorCommand
    }

    private var displayedConnectedDeviceCount: Int {
        if isReady || canAcceptDoorCommand {
            return max(connectedDeviceCount, 1)
        }

        return connectedDeviceCount
    }

    private var displayedMaximumConnectedDeviceCount: Int {
        max(maximumConnectedDeviceCount, 4)
    }

    var hasTrustedPairingForSecureCommand: Bool {
        (isPaired || hasKnownPairedController) && !hasRejectedCurrentSecurePairing
    }

    private var isSecureCommandWriteReady: Bool {
        commandCharacteristic != nil &&
            controlCharacteristic != nil &&
            peripheral?.state == .connected &&
            hasTrustedPairingForSecureCommand
    }

    private var canQueueDoorCommandForKnownController: Bool {
        guard hasTrustedPairingForSecureCommand else {
            return false
        }

        if isSecureCommandWriteReady {
            return true
        }

        if central?.state == .poweredOn {
            switch connectionState {
            case "Scanning", "Connecting", "Discovering", "Reconnecting", "Restoring", "Starting", "Known controller", "Disconnected":
                return true
            default:
                return peripheral?.state == .connected || peripheral?.state == .connecting
            }
        }

        guard hasKnownController,
              bluetoothState == "Starting" || bluetoothState == "Unknown" else {
            return false
        }

        return central == nil || central?.state == .unknown || central?.state == .resetting
    }

    var canQueueControllerSettingForKnownController: Bool {
        isReady || canQueueDoorCommandForKnownController
    }

    private var controllerSettingPendingStatusTitle: String {
        canQueueControllerSettingForKnownController ? "Setting..." : "Waiting for controller"
    }

    private var hasKnownController: Bool {
        peripheral != nil || UserDefaults.standard.string(forKey: Self.knownPeripheralIdentifierKey) != nil
    }

    private var shouldDeferRefreshScan: Bool {
        if peripheral?.state == .connecting {
            return true
        }

        if peripheral?.state == .connected,
           commandCharacteristic == nil
            || stateCharacteristic == nil
            || pairingCharacteristic == nil
            || controlCharacteristic == nil {
            return true
        }

        switch connectionState {
        case "Connecting", "Discovering", "Reconnecting", "Restoring", "Known controller", "Starting":
            return true
        default:
            return false
        }
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
            return DoorControllerSettingFormatter.title(for: "lock_name", value: DoorControllerSettingFormatter.shortValue(value))
        }

        if let value = pendingDeviceDisplayName ?? sentDeviceDisplayName {
            return DoorControllerSettingFormatter.title(for: "device_name", value: DoorControllerSettingFormatter.shortValue(value))
        }

        if servoAnglesApplyTask != nil || pendingServoAngles != nil || queuedServoAngles != nil || sentServoAngles != nil {
            let angles = pendingServoAngles ?? queuedServoAngles ?? sentServoAngles ?? ServoAngles(lockAngle: servoLockAngle, unlockAngle: servoUnlockAngle)
            return DoorControllerSettingFormatter.title(for: "servo_angles", value: DoorControllerSettingFormatter.servoAnglesValue(angles))
        }

        if autoLockApplyTask != nil || pendingAutoLockTimeoutSeconds != nil || queuedAutoLockTimeoutSeconds != nil {
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

    private static func formattedDistance(_ meters: Double, unit: DistanceUnit) -> String {
        DoorControllerPolicy.formattedDistance(meters, unit: unit.policyUnit)
    }

    func formattedDistance(_ meters: Double) -> String {
        Self.formattedDistance(meters, unit: distanceUnit)
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

    override init() {
        super.init()
#if DEBUG
        recordStartupTelemetry("controller_init")
#endif
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
#if DEBUG
        recordStartupTelemetry("central_created")
#endif
        UserDefaults.standard.removeObject(forKey: Self.legacyProximityUnlockArmedAtKey)
        if proximityUnlockArmedAt != nil {
            beginProximityUnlockBackgroundTask()
        }
        updateProximityUnlockStatus()
        scheduleDeferredStartupHousekeeping()
    }

    private func recordStartupTelemetry(_ event: String, details: String? = nil, once: Bool = true) {
#if DEBUG
        if once, startupTelemetryEvents.contains(event) {
            return
        }
        if once {
            startupTelemetryEvents.insert(event)
        }

        let elapsedMilliseconds = Int(((ProcessInfo.processInfo.systemUptime - startupTelemetryStartedAt) * 1000).rounded())
        let entry = StartupTelemetryEntry(
            elapsedMilliseconds: elapsedMilliseconds,
            event: event,
            details: details?.isEmpty == false ? details : nil
        )
        startupTelemetryEntries.append(entry)
        if startupTelemetryEntries.count > 48 {
            startupTelemetryEntries.removeFirst(startupTelemetryEntries.count - 48)
        }

        if let details, !details.isEmpty {
            print("DUStartup \(elapsedMilliseconds)ms \(event) \(details)")
        } else {
            print("DUStartup \(elapsedMilliseconds)ms \(event)")
        }
#endif
    }

    private func recordStartupStateChange(_ event: String, from oldValue: String, to newValue: String) {
        guard oldValue != newValue else { return }
        recordStartupTelemetry(event, details: "\(oldValue) -> \(newValue)", once: false)
    }

    private func scheduleDeferredStartupHousekeeping() {
        startupHousekeepingTask?.cancel()
        startupHousekeepingTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            await MainActor.run {
                self?.runDeferredStartupHousekeeping()
            }
        }
    }

    private func runDeferredStartupHousekeeping() {
        startupHousekeepingTask = nil
        refreshNotificationSettings()
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
        startupHousekeepingTask?.cancel()
        stateSnapshotFallbackTask?.cancel()
        firmwareVersionSnapshotRetryTask?.cancel()
        controlNonceRecoveryTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    private static func storedProximityUnlockEnabled() -> Bool {
        UserDefaults.standard.bool(forKey: proximityUnlockKey)
    }

    private static func storedInitialServoState() -> String {
        switch DoorStatusStore.load().state {
        case "locked":
            return "locked"
        case "unlocked":
            return "unlocked"
        case "locking":
            return "locked"
        case "unlocking":
            return "unlocked"
        default:
            return "unknown"
        }
    }

    private static func storedProximityUnlockRSSIThreshold() -> Int? {
        guard UserDefaults.standard.object(forKey: proximityUnlockRSSIThresholdKey) != nil else {
            return nil
        }

        return DoorControllerPolicy.clampedProximityUnlockRSSIThreshold(UserDefaults.standard.integer(forKey: proximityUnlockRSSIThresholdKey))
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
        return DoorControllerPolicy.clampedAutoLockSeconds(seconds)
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

        return DoorControllerPolicy.sanitizedName(name, fallback: "Device")
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
        return DoorControllerPolicy.clampedLockZoneRadiusMeters(radius)
    }

    private static func storedLockZoneUpdatedAt() -> Date? {
        let timestamp = UserDefaults.standard.double(forKey: lockZoneUpdatedAtKey)
        guard timestamp > 0 else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }

    private static func storedUnlockHoldDurationSeconds() -> Double {
        let storedValue = UserDefaults.standard.double(forKey: unlockHoldDurationKey)
        let seconds = storedValue == 0 ? defaultUnlockHoldDurationSeconds : storedValue
        return DoorControllerPolicy.clampedUnlockHoldDurationSeconds(seconds)
    }

    private static func storedDeviceDisplayName() -> String {
        if let storedName = UserDefaults.standard.string(forKey: deviceDisplayNameKey) {
            let sanitizedName = DoorControllerPolicy.sanitizedName(storedName, fallback: "iPhone")
            if !sanitizedName.isEmpty {
                return sanitizedName
            }
        }

        return DoorControllerPolicy.sanitizedName(UIDevice.current.name, fallback: "iPhone")
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
        let clampedSeconds = DoorControllerPolicy.clampedUnlockHoldDurationSeconds(seconds)
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
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [doorUnlockerUnlockNotificationIdentifier])
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
            if peripheral?.state == .connected {
                startRSSIMonitoringIfNeeded()
            }
        } else {
            stopRSSIMonitoring()
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
        let threshold = DoorControllerPolicy.clampedProximityUnlockRSSIThreshold(rssi)
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
        let clampedMeters = DoorControllerPolicy.clampedLockZoneRadiusMeters(meters)
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
        let clampedSeconds = DoorControllerPolicy.clampedAutoLockSeconds(seconds)
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
        let angles = DoorControllerPolicy.clampedServoAngles(requestedAngles)
        guard DoorControllerPolicy.servoAnglesAreValid(angles) else {
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
        servoAnglesStatus = controllerSettingPendingStatusTitle
        scheduleServoAnglesApply()
    }

    func updateDeviceDisplayName(_ name: String) {
        let sanitizedName = DoorControllerPolicy.sanitizedName(name, fallback: "Device")
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
        deviceDisplayNameStatus = controllerSettingPendingStatusTitle
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
        lockNameStatus = controllerSettingPendingStatusTitle
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

    var bundledFirmwarePackageURL: URL? {
        Bundle.main.url(forResource: "DoorUnlockerXiao-dfu", withExtension: "zip")
    }

    func startBundledFirmwareUpdate() {
        guard let url = bundledFirmwarePackageURL else {
#if DEBUG
            recordStartupTelemetry("firmware_bundle_missing", once: false)
#endif
            lastError = "No bundled firmware update package was found."
            return
        }

#if DEBUG
        recordStartupTelemetry("firmware_bundle_found", details: url.lastPathComponent, once: false)
#endif
        startFirmwareUpdate(packageURL: url)
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

    private static func debugLaunchArgumentValue(named name: String) -> String? {
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

    private static func debugFirmwareVerifiedNotificationName(for version: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let suffix = version.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? String(scalar) : "_"
        }.joined()
        return "\(debugFirmwareVerifiedNotificationPrefix).\(suffix)"
    }

    private func handleDebugFirmwareVersionVerification(_ version: String) {
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

    func startFirmwareUpdate(fromExternalPackageURL url: URL) {
        do {
            let localURL = try copyFirmwarePackageToTemporaryLocation(from: url)
            startFirmwareUpdate(packageURL: localURL)
        } catch {
            lastError = error.localizedDescription
            firmwareUpdateStatus = "Could not prepare firmware package"
            firmwareUpdateProgress = nil
            isFirmwareUpdateRunning = false
        }
    }

    private func copyFirmwarePackageToTemporaryLocation(from url: URL) throws -> URL {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("DoorUnlockerFirmware", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let packageURL = destination.appendingPathComponent("DoorUnlockerXiao-dfu.zip")
        if FileManager.default.fileExists(atPath: packageURL.path) {
            try FileManager.default.removeItem(at: packageURL)
        }
        try FileManager.default.copyItem(at: url, to: packageURL)
        return packageURL
    }

    private func startFirmwareUpdate(packageURL: URL) {
        guard !isFirmwareUpdateRunning else {
#if DEBUG
            recordStartupTelemetry("firmware_start_ignored_running", once: false)
#endif
            return
        }
        guard areSettingsUnlocked else {
#if DEBUG
            recordStartupTelemetry("firmware_start_blocked_settings_locked", once: false)
#endif
            lastError = "Open settings with Face ID or passcode before updating firmware."
            return
        }

        guard packageURL.pathExtension.localizedCaseInsensitiveCompare("zip") == .orderedSame else {
#if DEBUG
            recordStartupTelemetry("firmware_start_blocked_not_zip", details: packageURL.pathExtension, once: false)
#endif
            lastError = "Choose a firmware .zip package."
            return
        }

#if DEBUG
        recordStartupTelemetry("firmware_start_pending", details: packageURL.lastPathComponent, once: false)
#endif
        cancelFirmwareUpdateSuccessReset()
        pendingFirmwareUpdatePackageURL = packageURL
        firmwareUpdateEntryCommandSent = false
        firmwareDfuStartFallbackTask?.cancel()
        firmwareDfuStartFallbackTask = nil
        firmwareUpdateStatus = "Preparing secure firmware update"
        firmwareUpdateProgress = nil
        isFirmwareUpdateRunning = true
        lastError = nil
        requestFirmwareUpdateNotificationAuthorizationIfNeeded()

        if !sendPendingFirmwareUpdateCommandIfReady() {
            requestControllerConnectionIfNeeded()
        }
    }

    @discardableResult
    private func sendPendingFirmwareUpdateCommandIfReady() -> Bool {
        guard let packageURL = pendingFirmwareUpdatePackageURL else {
#if DEBUG
            recordStartupTelemetry("firmware_send_skipped_no_pending", once: false)
#endif
            return false
        }
        guard !firmwareUpdateEntryCommandSent else {
#if DEBUG
            recordStartupTelemetry("firmware_send_skipped_already_sent", once: false)
#endif
            return false
        }

        guard isReady else {
#if DEBUG
            recordStartupTelemetry("firmware_send_waiting_ready", details: connectionState, once: false)
#endif
            firmwareUpdateStatus = "Connecting to controller"
            requestControllerConnectionIfNeeded()
            return false
        }

        guard fastCommandNonce != nil else {
#if DEBUG
            recordStartupTelemetry("firmware_send_waiting_nonce", once: false)
#endif
            firmwareUpdateStatus = "Preparing secure command"
            requestFreshSecureControlNonce()
            return false
        }

#if DEBUG
        recordStartupTelemetry("firmware_send_enter_ota", once: false)
#endif
        firmwareUpdateStatus = "Requesting firmware update mode"
        if writeAuthenticatedCommand("ENTER_OTA_DFU", intent: .firmwareUpdate(packageURL)) {
#if DEBUG
            recordStartupTelemetry("firmware_send_enter_ota_written", once: false)
#endif
            firmwareUpdateEntryCommandSent = true
            stopSecureLinkWatchdog()
            return true
        }

#if DEBUG
        recordStartupTelemetry("firmware_send_enter_ota_failed", once: false)
#endif
        firmwareUpdateStatus = "Could not request firmware update mode"
        isFirmwareUpdateRunning = false
        pendingFirmwareUpdatePackageURL = nil
        firmwareUpdateEntryCommandSent = false
        return false
    }

    private func beginFirmwareDfuUpload(after packageURL: URL) {
        firmwareUpdateStatus = "Waiting for update bootloader"
        firmwareUpdateProgress = nil
        firmwareDfuStartFallbackTask?.cancel()
        firmwareDfuStartFallbackTask = nil
        prepareControllerSessionForFirmwareDfu()
        firmwareDfuManager.start(packageURL: packageURL)
    }

    private func beginPendingFirmwareDfuUploadIfNeeded() {
        guard let packageURL = pendingFirmwareUpdatePackageURL else { return }
        pendingFirmwareUpdatePackageURL = nil
        firmwareUpdateEntryCommandSent = false
        beginFirmwareDfuUpload(after: packageURL)
    }

    private func scheduleFirmwareDfuStartFallback(after delay: TimeInterval = 0.8) {
        guard pendingFirmwareUpdatePackageURL != nil else { return }

        firmwareDfuStartFallbackTask?.cancel()
        firmwareDfuStartFallbackTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            await MainActor.run {
                guard let self,
                      self.isFirmwareUpdateRunning,
                      self.pendingFirmwareUpdatePackageURL != nil else {
                    return
                }

                self.beginPendingFirmwareDfuUploadIfNeeded()
            }
        }
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
        autoLockStatus = controllerSettingPendingStatusTitle

        autoLockApplyTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
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
            autoLockStatus = controllerSettingPendingStatusTitle
            requestControllerConnectionIfNeeded()
            return
        }

        let commandText = "SET_TIMEOUT:\(autoLockSeconds)"
        pendingAutoLockTimeoutSeconds = autoLockSeconds
        autoLockStatus = "Setting..."

        guard fastCommandNonce != nil else {
            queuedAutoLockTimeoutSeconds = autoLockSeconds
            autoLockStatus = controllerSettingPendingStatusTitle
            requestFreshSecureControlNonce()
            return
        }

        if !writeAuthenticatedCommand(commandText, intent: .autoLockTimeout(autoLockSeconds)) {
            pendingAutoLockTimeoutSeconds = nil
            autoLockStatus = "Not set"
        }
    }

    private func scheduleServoAnglesApply() {
        servoAnglesApplyTask?.cancel()
        servoAnglesStatus = controllerSettingPendingStatusTitle

        servoAnglesApplyTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }

            await MainActor.run {
                self?.servoAnglesApplyTask = nil
                self?.applyServoAngles()
            }
        }
    }

    private func applyServoAngles() {
        let angles = pendingServoAngles ?? ServoAngles(lockAngle: servoLockAngle, unlockAngle: servoUnlockAngle)
        guard DoorControllerPolicy.servoAnglesAreValid(angles) else {
            servoAnglesStatus = "Not set"
            lastError = "Servo angles must stay inside \(Self.minimumServoAngle)-\(Self.maximumServoAngle) degrees and \(Self.minimumServoAngleGap) degrees apart."
            return
        }

        guard isReady else {
            queuedServoAngles = angles
            servoAnglesStatus = controllerSettingPendingStatusTitle
            requestControllerConnectionIfNeeded()
            return
        }

        guard fastCommandNonce != nil else {
            queuedServoAngles = angles
            servoAnglesStatus = controllerSettingPendingStatusTitle
            requestFreshSecureControlNonce()
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
        let confirmedSeconds = DoorControllerPolicy.clampedAutoLockSeconds(seconds)

        if pendingAutoLockTimeoutSeconds == confirmedSeconds {
            pendingAutoLockTimeoutSeconds = nil
        }

        if queuedAutoLockTimeoutSeconds == confirmedSeconds {
            queuedAutoLockTimeoutSeconds = nil
        }

        let hasNewerLocalIntent = autoLockSeconds != confirmedSeconds
            && (autoLockApplyTask != nil || pendingAutoLockTimeoutSeconds != nil || queuedAutoLockTimeoutSeconds != nil)

        guard !hasNewerLocalIntent else {
            autoLockStatus = controllerSettingPendingStatusTitle
            return
        }

        autoLockSeconds = confirmedSeconds
        UserDefaults.standard.set(autoLockSeconds, forKey: Self.autoLockSecondsKey)
        autoLockStatus = "Controller set to \(autoLockSeconds)s"
    }

    private func applyControllerServoAngles(_ angles: ServoAngles) {
        clearRemoteSettingApplying()
        let confirmedAngles = DoorControllerPolicy.clampedServoAngles(angles)
        guard DoorControllerPolicy.servoAnglesAreValid(confirmedAngles) else { return }

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
            servoAnglesStatus = controllerSettingPendingStatusTitle
            return
        }

        servoLockAngle = confirmedAngles.lockAngle
        servoUnlockAngle = confirmedAngles.unlockAngle
        servoAnglesStatus = "Controller set to \(confirmedAngles.lockAngle)° / \(confirmedAngles.unlockAngle)°"
    }

    func scan() {
        guard let central else {
            connectionState = "Starting"
            return
        }

        guard central.state == .poweredOn else {
            updateBluetoothAvailabilityState(central.state)
            return
        }

#if DEBUG
        recordStartupTelemetry("scan_requested", details: "state=\(connectionState)")
#endif
        lastError = nil
        reconnectTimer?.invalidate()

        if let peripheral {
            switch peripheral.state {
            case .connected:
                connectionState = hasDiscoveredControllerCharacteristics ? "Ready" : "Discovering"
                if !hasDiscoveredControllerCharacteristics {
                    discoverControllerServices(on: peripheral)
                } else {
                    _ = finishConnectionIfReady()
                    readStateIfPermitted()
                }
                updateProximityUnlockStatus()
                return
            case .connecting:
                connectionState = "Connecting"
                updateProximityUnlockStatus()
                scheduleReconnectCheck(after: reconnectCheckDelay(8))
                return
            case .disconnecting:
                connectionState = "Reconnecting"
                updateProximityUnlockStatus()
                scheduleReconnectCheck(after: reconnectCheckDelay(8))
                return
            case .disconnected:
                break
            @unknown default:
                break
            }
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

    private func updateBluetoothAvailabilityState(_ state: CBManagerState) {
        switch state {
        case .poweredOn:
            bluetoothState = "On"
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
    }

    func refreshStateFromController() {
        reconcilePredictedAutoLock()
        if !readStateIfPermitted() {
            requestControllerConnectionIfNeeded()
        }
    }

    func requestControllerConnectionIfNeeded() {
        guard !shouldDeferRefreshScan else { return }
        scan()
    }

    func toggleLock() {
        send(isUnlocked ? .lock : .unlock)
    }

    func performPendingSystemCommand() {
        guard let systemCommand = DoorCommandStore.takePendingCommand() else { return }
        runSystemCommand(systemCommand)
    }

    @discardableResult
    func send(_ command: Command) -> Bool {
        if command == .unlock && requiresUnlockAuthentication {
            Task {
                await authenticateAndSendUnlock()
            }
            return true
        }

        return sendAuthenticated(command)
    }

    @discardableResult
    private func sendAuthenticated(_ command: Command, origin: DoorCommandOrigin = .manual) -> Bool {
        cancelPostReadySync()
        return sendDoorCommandAttempt(
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
        if !didWrite,
           hasTrustedPairingForSecureCommand,
           pendingFreshNonceDoorCommand == nil,
           ((isReady && preparedFastDoorCommandPayloads[command] == nil) || canQueueDoorCommandForKnownController) {
            pendingFreshNonceDoorCommand = PendingFreshNonceDoorCommand(
                command: command,
                attempt: attempt,
                previousServoState: previousServoState,
                origin: origin
            )
            lastError = nil
            prepareConnectionForQueuedDoorCommand()
            return true
        }
        return didWrite
    }

    private func prepareConnectionForQueuedDoorCommand() {
        if isSecureCommandWriteReady {
            if let nonce = fastCommandNonce {
                if preparedFastDoorCommandTask == nil {
                    prepareFastDoorCommandPayloads(for: nonce)
                }
                return
            }

            requestFreshSecureControlNonce()
            return
        }

        guard central?.state == .poweredOn else {
            return
        }

        if !connectToKnownPeripheralIfPossible() {
            startScan()
        }
    }

    private func scheduleDoorCommandRecovery(_ command: Command, sentAt: Date, attempt: Int, origin: DoorCommandOrigin) {
        doorCommandRecoveryTask?.cancel()
        doorCommandRecoveryTask = Task { [weak self] in
            let readDelays: [UInt64] = [250_000_000, 350_000_000, 800_000_000, 1_600_000_000]
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
                    if self.optimisticDoorCommandAcknowledged,
                       Date().timeIntervalSince(sentAt) >= Self.acknowledgedDoorCommandSettleDelay {
                        self.settleOptimisticDoorCommand(command)
                        return false
                    }
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

                if self.optimisticDoorCommandAcknowledged {
                    self.settleOptimisticDoorCommand(command)
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
    func writeAuthenticatedCommand(_ commandText: String, intent: CommandWriteIntent) -> Bool {
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

        if let doorCommand,
           let nonce = fastCommandNonce {
            let fastPayload: DoorCommandAuthenticator.SignedFastCommandPayload
            do {
                fastPayload = try DoorCommandAuthenticator.fastCommandPayload(for: doorCommand, nonce: nonce)
            } catch {
                lastError = error.localizedDescription
                return false
            }

            guard let fastWriteType = preferredFastDoorCommandWriteType(
                for: fastPayload.data,
                peripheral: peripheral,
                characteristic: commandCharacteristic
            ) else {
                lastError = "Secure command is too large for this BLE connection"
                return false
            }

            invalidatePreparedFastDoorCommandPayloads(clearNonce: true)
            lastError = nil
            peripheral.writeValue(fastPayload.data, for: commandCharacteristic, type: fastWriteType)
            return true
        }

        if doorCommand != nil {
            lastError = nil
            return false
        }

        guard let nonce = fastCommandNonce else {
            lastError = nil
            requestFreshSecureControlNonce()
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
        if writeType == .withoutResponse, case .firmwareUpdate = intent {
            firmwareUpdateStatus = "Waiting for controller update mode"
            scheduleFirmwareDfuStartFallback()
        }
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
        let commandOrder = fastDoorCommandPreparationOrder()

        preparedFastDoorCommandTask?.cancel()
        preparedFastDoorCommandTask = Task { [weak self] in
            for command in commandOrder {
                let payload = try? await Task.detached(priority: .userInitiated) {
                    try DoorCommandAuthenticator.fastCommandPayload(for: command, nonce: nonce)
                }.value

                guard !Task.isCancelled else { return }
                guard let payload else {
                    await MainActor.run {
                        guard let self,
                              self.preparedFastDoorCommandGeneration == generation,
                              self.fastCommandNonce == nonce else {
                            return
                        }

                        self.preparedFastDoorCommandTask = nil
                        self.fastCommandNonce = nil
                        self.startSecureLinkWatchdogIfNeeded()
                    }
                    return
                }

                let shouldContinue = await MainActor.run {
                    guard let self,
                          self.preparedFastDoorCommandGeneration == generation,
                          self.fastCommandNonce == nonce,
                          self.hasTrustedPairingForSecureCommand else {
                        return false
                    }

                    self.preparedFastDoorCommandPayloads[command] = payload
#if DEBUG
                    if self.preparedFastDoorCommandPayloads.count == 1 {
                        self.recordStartupTelemetry("first_fast_payload_ready", details: command.rawValue)
                    }
#endif
                    self.stopSecureLinkWatchdog()
                    if self.sendPendingFreshNonceDoorCommandIfReady() {
                        return false
                    }
                    self.sendPendingSystemCommandIfReady()
                    _ = self.runProximityUnlockIfReady()
                    return self.preparedFastDoorCommandGeneration == generation &&
                        self.fastCommandNonce == nonce
                }

                guard shouldContinue else { return }
            }

            await MainActor.run {
                guard let self,
                      self.preparedFastDoorCommandGeneration == generation,
                      self.fastCommandNonce == nonce,
                      self.hasTrustedPairingForSecureCommand else {
                    return
                }

                self.preparedFastDoorCommandTask = nil
                self.stopSecureLinkWatchdog()
                if self.sendPendingFreshNonceDoorCommandIfReady() {
                    return
                }
                self.sendPendingSystemCommandIfReady()
                _ = self.runProximityUnlockIfReady()
                guard self.fastCommandNonce == nonce else { return }
                self.schedulePostReadySync()
            }
        }
    }

    private func fastDoorCommandPreparationOrder() -> [Command] {
        let first = pendingFreshNonceDoorCommand?.command ?? (isUnlocked ? .lock : .unlock)
        let second: Command = first == .unlock ? .lock : .unlock
        return [first, second]
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
        if linkAuthenticationInFlight {
            linkAuthenticationInFlight = false
            hasAuthenticatedCurrentLink = true
#if DEBUG
            recordStartupTelemetry("door_command_usable", details: "link_authenticated")
#endif
        }
        fastCommandNonce = nonce
#if DEBUG
        recordStartupTelemetry("secure_nonce_received")
        recordStartupTelemetry("door_command_usable", details: "nonce_ready")
#endif
        if sendPendingFirmwareUpdateCommandIfReady() {
            return
        }
        if pendingFreshNonceDoorCommand == nil,
           sendQueuedControllerSettingIfReady() {
            return
        }
        if sendLinkAuthenticationProbeIfNeeded() {
            return
        }
        prepareFastDoorCommandPayloads(for: nonce)
    }

    @discardableResult
    private func sendLinkAuthenticationProbeIfNeeded() -> Bool {
        guard needsLinkAuthentication,
              fastCommandNonce != nil,
              isReady else {
            return false
        }

        linkAuthenticationInFlight = true
        if writeAuthenticatedCommand("GET_LOCK_NAME", intent: .linkAuthentication) {
#if DEBUG
            recordStartupTelemetry("link_auth_probe_sent", once: false)
#endif
            return true
        }

        linkAuthenticationInFlight = false
        return false
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
            deviceDisplayNameStatus = controllerSettingPendingStatusTitle
            requestControllerConnectionIfNeeded()
            return
        }
        guard fastCommandNonce != nil else {
            pendingDeviceDisplayName = nameToSync
            deviceDisplayNameStatus = controllerSettingPendingStatusTitle
            requestFreshSecureControlNonce()
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
            lockNameStatus = controllerSettingPendingStatusTitle
            requestControllerConnectionIfNeeded()
            return
        }
        guard fastCommandNonce != nil else {
            pendingLockName = nameToSync
            lockNameStatus = controllerSettingPendingStatusTitle
            requestFreshSecureControlNonce()
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
            lockNameStatus = controllerSettingPendingStatusTitle
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
                self?.retryUnconfirmedLockName()
            }
        }
    }

    private func retryUnconfirmedLockName() {
        guard let name = sentLockName else { return }

        sentLockName = nil
        pendingLockName = name
        lockNameStatus = canQueueControllerSettingForKnownController ? "Retrying..." : "Waiting for controller"
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
        if linkAuthenticationInFlight {
            linkAuthenticationInFlight = false
            hasAuthenticatedCurrentLink = false
        }

        if reason == "bad_signature" || reason == "unpaired" {
            hasRejectedCurrentSecurePairing = true
        }

        if isFirmwareUpdateRunning {
            pendingFirmwareUpdatePackageURL = nil
            firmwareUpdateEntryCommandSent = false
            firmwareDfuStartFallbackTask?.cancel()
            firmwareDfuStartFallbackTask = nil
            firmwareDfuManager.cancel()
            firmwareUpdateProgress = nil
            isFirmwareUpdateRunning = false
            switch reason {
            case "unpaired", "bad_signature":
                firmwareUpdateStatus = "Pair this iPhone before updating firmware"
                lastError = "Pair this iPhone before updating firmware."
            case "bad_nonce", "missing_nonce":
                firmwareUpdateStatus = "Controller asked for a fresh secure command"
                lastError = "Controller asked for a fresh secure command."
            case "busy":
                firmwareUpdateStatus = "Controller is busy"
                lastError = "Controller is busy."
            default:
                firmwareUpdateStatus = "Firmware update rejected"
                lastError = "Controller rejected firmware update."
            }
        }

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
            requestFreshSecureControlNonce()
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
        optimisticDoorCommandAcknowledged = false
        optimisticDoorPreviousServoState = nil
        doorCommandRecoveryTask?.cancel()
        doorCommandRecoveryTask = nil
    }

    @discardableResult
    private func sendPendingFreshNonceDoorCommandIfReady() -> Bool {
        guard let pendingFreshNonceDoorCommand,
              preparedFastDoorCommandPayloads[pendingFreshNonceDoorCommand.command] != nil else {
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
                self?.retryUnconfirmedDeviceDisplayName()
            }
        }
    }

    private func retryUnconfirmedDeviceDisplayName() {
        guard let name = sentDeviceDisplayName else { return }

        sentDeviceDisplayName = nil
        pendingDeviceDisplayName = name
        deviceDisplayNameStatus = canQueueControllerSettingForKnownController ? "Retrying..." : "Waiting for controller"
        syncDeviceDisplayNameIfReady()
    }

    private func runSystemCommand(_ systemCommand: DoorSystemCommand) {
        switch systemCommand {
        case .lock:
            if !send(.lock) {
                pendingSystemCommand = systemCommand
                requestControllerConnectionIfNeeded()
            }
        case .unlock:
            if !send(.unlock) {
                pendingSystemCommand = systemCommand
                requestControllerConnectionIfNeeded()
            }
        case .toggle:
            guard hasKnownLockState else {
                pendingSystemCommand = systemCommand
                _ = readStateIfPermitted()
                requestControllerConnectionIfNeeded()
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
        scheduleReconnectCheck(after: Self.fastKnownControllerRetryDelay)
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
            || pendingFreshNonceDoorCommand?.origin == .proximity
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
        let region = CLCircularRegion(center: lockZoneCenter, radius: radius, identifier: doorUnlockerLockZoneRegionIdentifier)
        region.notifyOnEntry = true
        region.notifyOnExit = true
        locationManager.startMonitoring(for: region)
        locationManager.requestState(for: region)
        requestLockZoneLocationSnapshotIfAvailable()
        startProximityBackgroundLocationMonitoringIfNeeded()
    }

    private func stopLockZoneMonitoring() {
        for region in locationManager.monitoredRegions where region.identifier == doorUnlockerLockZoneRegionIdentifier {
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
            peripheral?.readRSSI()
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

        knownPeripheralAssistScanTask?.cancel()
        knownPeripheralAssistScanTask = nil
        connectionState = "Scanning"
        updateProximityUnlockStatus()
        startControllerScanIfNeeded()
        scheduleReconnectCheck(after: reconnectCheckDelay(5))
    }

    private func startControllerScanIfNeeded() {
        guard let central, central.state == .poweredOn else { return }

        let allowsDuplicates = proximityUnlockArmedAt != nil
        if central.isScanning, activeScanAllowsDuplicates == allowsDuplicates {
            return
        }

        central.stopScan()
        activeScanAllowsDuplicates = allowsDuplicates
        central.scanForPeripherals(
            withServices: [serviceUUID],
            options: scanOptionsForCurrentMode(allowsDuplicates: allowsDuplicates)
        )
    }

    private func stopControllerScan() {
        central?.stopScan()
        activeScanAllowsDuplicates = nil
    }

    private func scheduleKnownPeripheralAssistScan(after delay: TimeInterval? = nil) {
        knownPeripheralAssistScanTask?.cancel()
        knownPeripheralAssistScanTask = Task { [weak self] in
            let delay = delay ?? Self.fastKnownControllerRetryDelay
            let nanoseconds = UInt64(max(0, delay) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)

            await MainActor.run {
                guard let self,
                      self.central?.state == .poweredOn,
                      !self.isSecureCommandWriteReady else {
                    return
                }

                guard let peripheral = self.peripheral,
                      peripheral.state == .connecting || peripheral.state == .disconnected else {
                    return
                }

                self.startControllerScanIfNeeded()
                self.knownPeripheralAssistScanTask = nil
            }
        }
    }

    private func scanOptionsForCurrentMode(allowsDuplicates: Bool? = nil) -> [String: Any] {
        [
            CBCentralManagerScanOptionAllowDuplicatesKey: allowsDuplicates ?? (proximityUnlockArmedAt != nil)
        ]
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
        guard let central else {
            return false
        }

        if let identifierText = UserDefaults.standard.string(forKey: Self.knownPeripheralIdentifierKey),
           let identifier = UUID(uuidString: identifierText),
           let knownPeripheral = central.retrievePeripherals(withIdentifiers: [identifier]).first,
           knownPeripheral.state != .disconnecting {
#if DEBUG
            recordStartupTelemetry("known_peripheral_retrieved", details: "state=\(knownPeripheral.state.rawValue)")
#endif
            restoreOrConnect(to: knownPeripheral, reason: "Known controller")
            return true
        }

        let connectedDoorPeripherals = central.retrieveConnectedPeripherals(withServices: [serviceUUID])
        guard let connectedPeripheral = connectedDoorPeripherals.first(where: { $0.state == .connected || $0.state == .connecting })
            ?? connectedDoorPeripherals.first else {
            return false
        }

#if DEBUG
        recordStartupTelemetry("connected_peripheral_retrieved", details: "state=\(connectedPeripheral.state.rawValue)")
#endif
        restoreOrConnect(to: connectedPeripheral, reason: "Known controller")
        return true
    }

    private func connect(to peripheral: CBPeripheral) {
        guard let central else { return }

        saveKnownPeripheral(peripheral)

        if self.peripheral?.identifier == peripheral.identifier {
            if peripheral.state == .connected {
                connectionState = hasDiscoveredControllerCharacteristics ? "Ready" : "Discovering"
                clearProximityUnlockCandidateIfUnarmed()
                updateProximityUnlockStatus()
                if !hasDiscoveredControllerCharacteristics {
                    discoverControllerServices(on: peripheral)
                }
                return
            }

            if peripheral.state == .connecting {
                connectionState = "Connecting"
                clearProximityUnlockCandidateIfUnarmed()
                updateProximityUnlockStatus()
                scheduleReconnectCheck(after: reconnectCheckDelay(5))
                scheduleKnownPeripheralAssistScan()
                return
            }
        } else if let currentPeripheral = self.peripheral,
                  currentPeripheral.state == .connecting || currentPeripheral.state == .connected {
            central.cancelPeripheralConnection(currentPeripheral)
        }

        if self.peripheral?.identifier != peripheral.identifier {
            clearDiscoveredControllerCharacteristics()
        }
        self.peripheral = peripheral
        self.peripheral?.delegate = self

        if peripheral.state == .connected {
#if DEBUG
            recordStartupTelemetry("connect_reused_connected")
#endif
            connectionState = "Discovering"
            clearProximityUnlockCandidateIfUnarmed()
            updateProximityUnlockStatus()
            discoverControllerServices(on: peripheral)
            return
        }

        if peripheral.state == .connecting {
#if DEBUG
            recordStartupTelemetry("connect_reused_connecting")
#endif
            connectionState = "Connecting"
            clearProximityUnlockCandidateIfUnarmed()
            updateProximityUnlockStatus()
            scheduleReconnectCheck(after: reconnectCheckDelay(5))
            scheduleKnownPeripheralAssistScan()
            return
        }

#if DEBUG
        recordStartupTelemetry("connect_start")
#endif
        connectionState = "Connecting"
        clearProximityUnlockCandidateIfUnarmed()
        updateProximityUnlockStatus()
        stopControllerScan()
        central.connect(peripheral, options: nil)
        scheduleReconnectCheck(after: reconnectCheckDelay(6))
        scheduleKnownPeripheralAssistScan()
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
        postReadySyncTask?.cancel()
        postReadySyncTask = nil
        stateSnapshotFallbackTask?.cancel()
        stateSnapshotFallbackTask = nil
        firmwareVersionSnapshotRetryTask?.cancel()
        firmwareVersionSnapshotRetryTask = nil
        controlNonceRecoveryTask?.cancel()
        controlNonceRecoveryTask = nil
        knownPeripheralAssistScanTask?.cancel()
        knownPeripheralAssistScanTask = nil
        commandCharacteristic = nil
        stateCharacteristic = nil
        pairingCharacteristic = nil
        controlCharacteristic = nil
        stopSecureLinkWatchdog()
        stopRSSIMonitoring()
        resetLinkAuthentication()
        pendingCommandWriteIntents.removeAll()
        invalidatePreparedFastDoorCommandPayloads(clearNonce: true)
    }

    private func prepareControllerSessionForFirmwareDfu() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        stopControllerScan()
        clearDiscoveredControllerCharacteristics()
        pendingCommandWriteIntents.removeAll()
        pairingState = "Unknown"
        pairingApprovalCode = nil
        connectionState = "Updating firmware"
        updateProximityUnlockStatus()
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
#if DEBUG
            recordStartupTelemetry("restore_connected", details: reason)
#endif
            reconnectTimer?.invalidate()
            connectionState = hasDiscoveredControllerCharacteristics ? reason : "Discovering"
            clearProximityUnlockCandidateIfUnarmed()
            updateProximityUnlockStatus()
            discoverControllerServices(on: restoredPeripheral)
        case .connecting:
#if DEBUG
            recordStartupTelemetry("restore_connecting", details: reason)
#endif
            connectionState = "Reconnecting"
            clearProximityUnlockCandidateIfUnarmed()
            updateProximityUnlockStatus()
            scheduleKnownPeripheralAssistScan()
        case .disconnected, .disconnecting:
#if DEBUG
            recordStartupTelemetry("restore_connect_start", details: reason)
#endif
            connectionState = "Reconnecting"
            clearProximityUnlockCandidateIfUnarmed()
            updateProximityUnlockStatus()
            stopControllerScan()
            central.connect(restoredPeripheral, options: nil)
            scheduleReconnectCheck(after: reconnectCheckDelay(6))
            scheduleKnownPeripheralAssistScan()
        @unknown default:
            connectionState = "Reconnecting"
            updateProximityUnlockStatus()
            stopControllerScan()
            central.connect(restoredPeripheral, options: nil)
            scheduleReconnectCheck(after: reconnectCheckDelay(6))
            scheduleKnownPeripheralAssistScan()
        }
    }

    private func discoverControllerServices(on peripheral: CBPeripheral) {
        peripheral.delegate = self

        let cachedDoorServices = peripheral.services?.filter { $0.uuid == serviceUUID } ?? []
        guard !cachedDoorServices.isEmpty else {
#if DEBUG
            recordStartupTelemetry("service_discovery_start")
#endif
            peripheral.discoverServices([serviceUUID])
            scheduleReconnectCheck(after: reconnectCheckDelay(6))
            return
        }

#if DEBUG
        recordStartupTelemetry("cached_service_available")
#endif
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
                if (characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate)),
                   !characteristic.isNotifying {
                    peripheral.setNotifyValue(true, for: characteristic)
                }
            } else if characteristic.uuid == pairingUUID {
                pairingCharacteristic = characteristic
            } else if characteristic.uuid == controlUUID {
                controlCharacteristic = characteristic
            }
        }

        enableControlNotificationsIfPossible(on: peripheral)
    }

    private func enableControlNotificationsIfPossible(on peripheral: CBPeripheral) {
        guard isCurrentPeripheral(peripheral),
              let controlCharacteristic else {
            return
        }

        if (controlCharacteristic.properties.contains(.notify) || controlCharacteristic.properties.contains(.indicate)),
           !controlCharacteristic.isNotifying {
            peripheral.setNotifyValue(true, for: controlCharacteristic)
        } else {
            scheduleControlNonceRecoveryIfNeeded()
        }
    }

    private func serviceHasAllRequiredCharacteristics(_ service: CBService) -> Bool {
        let characteristicUUIDs = Set((service.characteristics ?? []).map(\.uuid))
        return characteristicUUIDs.contains(commandUUID)
            && characteristicUUIDs.contains(stateUUID)
            && characteristicUUIDs.contains(pairingUUID)
            && characteristicUUIDs.contains(controlUUID)
    }

    private func hasPendingDoorCharacteristicDiscovery(on peripheral: CBPeripheral) -> Bool {
        let doorServices = peripheral.services?.filter { $0.uuid == serviceUUID } ?? []
        return doorServices.contains { $0.characteristics == nil }
    }

    @discardableResult
    private func finishConnectionIfReady() -> Bool {
        guard commandCharacteristic != nil,
              stateCharacteristic != nil,
              pairingCharacteristic != nil,
              controlCharacteristic != nil else {
            return false
        }

#if DEBUG
        recordStartupTelemetry("gatt_ready")
#endif
        reconnectTimer?.invalidate()
        knownPeripheralAssistScanTask?.cancel()
        knownPeripheralAssistScanTask = nil
        connectionState = "Ready"
        if proximityUnlockEnabled {
            startRSSIMonitoringIfNeeded()
        }
        _ = promoteKnownControllerPairingIfNeeded()
        requestFreshSecureControlNonce()
        scheduleStateSnapshotFallbackRead()
        scheduleFirmwareVersionSnapshotRetry()
        scheduleKnownPairingFallbackIfNeeded()
        pairFromInviteIfReady()
        if runProximityUnlockIfReady() {
            updateProximityUnlockStatus()
            return true
        }
        sendPendingSystemCommandIfReady()
        updateProximityUnlockStatus()
        return true
    }

    private func schedulePostReadySync() {
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

    private func cancelPostReadySync() {
        postReadySyncTask?.cancel()
        postReadySyncTask = nil
    }

    private func scheduleStateSnapshotFallbackRead(delay: Duration = .milliseconds(150)) {
        stateSnapshotFallbackTask?.cancel()
        let generation = stateUpdateGeneration
        stateSnapshotFallbackTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            await MainActor.run {
                guard let self,
                      self.stateUpdateGeneration == generation,
                      self.isReady else {
                    return
                }

                self.stateSnapshotFallbackTask = nil
                _ = self.readStateIfPermitted()
            }
        }
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
        guard secureLinkWatchdogTask == nil,
              needsFreshSecureNonce else { return }

        secureLinkWatchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                let shouldContinue = await MainActor.run { () -> Bool in
                    self?.needsFreshSecureNonce ?? false
                }

                guard shouldContinue else { break }

                await MainActor.run {
                    guard let self,
                          self.needsFreshSecureNonce,
                          self.peripheral != nil,
                          self.controlCharacteristic != nil else {
                        return
                    }

                    self.requestFreshSecureControlNonce()
                }

                try? await Task.sleep(for: .milliseconds(500))
            }

            await MainActor.run {
                self?.secureLinkWatchdogTask = nil
            }
        }
    }

    private var needsFreshSecureNonce: Bool {
        isReady &&
            fastCommandNonce == nil &&
            !isDoorCommandReady &&
            ((pendingFirmwareUpdatePackageURL != nil && !firmwareUpdateEntryCommandSent) ||
                pendingSystemCommand != nil ||
                needsLinkAuthentication ||
                needsFastCommandPreparation)
    }

    private var needsLinkAuthentication: Bool {
        !hasAuthenticatedCurrentLink &&
            !linkAuthenticationInFlight &&
            pendingFreshNonceDoorCommand == nil &&
            pendingSystemCommand == nil &&
            pendingFirmwareUpdatePackageURL == nil
    }

    private var needsFastCommandPreparation: Bool {
        hasAuthenticatedCurrentLink &&
            pendingFreshNonceDoorCommand == nil &&
            pendingSystemCommand == nil &&
            pendingFirmwareUpdatePackageURL == nil &&
            preparedFastDoorCommandPayloads.isEmpty
    }

    func requestFreshSecureControlNonce() {
        guard let peripheral,
              let controlCharacteristic else {
            startSecureLinkWatchdogIfNeeded()
            return
        }

#if DEBUG
        recordStartupTelemetry("secure_nonce_requested")
#endif
        if (controlCharacteristic.properties.contains(.notify) || controlCharacteristic.properties.contains(.indicate)),
           !controlCharacteristic.isNotifying {
            peripheral.setNotifyValue(true, for: controlCharacteristic)
        } else if controlCharacteristic.properties.contains(.notify) || controlCharacteristic.properties.contains(.indicate) {
            _ = readControlIfPermitted()
            scheduleControlNonceRecoveryIfNeeded(after: .milliseconds(250))
        } else {
            _ = readControlIfPermitted()
        }
        requestNonceViaCommandIfPossible()
        startSecureLinkWatchdogIfNeeded()
    }

    private func requestNonceViaCommandIfPossible() {
        guard let peripheral,
              let commandCharacteristic else {
            return
        }

        let payload = Data("nonce".utf8)
        if commandCharacteristic.properties.contains(.write) {
            peripheral.writeValue(payload, for: commandCharacteristic, type: .withResponse)
        } else if commandCharacteristic.properties.contains(.writeWithoutResponse),
                  peripheral.canSendWriteWithoutResponse {
            peripheral.writeValue(payload, for: commandCharacteristic, type: .withoutResponse)
        }
    }

    private func scheduleControlNonceRecoveryIfNeeded(after delay: Duration = .milliseconds(80)) {
        guard isReady,
              !isDoorCommandReady,
              fastCommandNonce == nil,
              (controlCharacteristic?.properties.contains(.notify) == true ||
                controlCharacteristic?.properties.contains(.indicate) == true) else {
            return
        }

        controlNonceRecoveryTask?.cancel()
        let generation = controlUpdateGeneration
        controlNonceRecoveryTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            await MainActor.run {
                guard let self,
                      self.controlUpdateGeneration == generation,
                      self.isReady,
                      !self.isDoorCommandReady,
                      self.fastCommandNonce == nil,
                      let peripheral = self.peripheral,
                      let controlCharacteristic = self.controlCharacteristic else {
                    return
                }

                if controlCharacteristic.isNotifying {
                    _ = self.readControlIfPermitted()
                    self.controlNonceRecoveryTask = nil
                } else {
                    peripheral.setNotifyValue(true, for: controlCharacteristic)
                    self.controlNonceRecoveryTask = nil
                }
            }
        }
    }

    private func stopSecureLinkWatchdog() {
        secureLinkWatchdogTask?.cancel()
        secureLinkWatchdogTask = nil
        controlNonceRecoveryTask?.cancel()
        controlNonceRecoveryTask = nil
    }

    private func resetLinkAuthentication() {
        hasAuthenticatedCurrentLink = false
        linkAuthenticationInFlight = false
    }

    private func reconnectCheckDelay(_ defaultDelay: TimeInterval) -> TimeInterval {
        min(defaultDelay, Self.activeConnectionRecoveryDelay)
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
            connectionState = "Connecting"
            updateProximityUnlockStatus()
            scheduleReconnectCheck(after: reconnectCheckDelay(8))
            return
        }

        if let peripheral, peripheral.state == .connected {
            connectionState = hasDiscoveredControllerCharacteristics ? "Ready" : "Discovering"
            updateProximityUnlockStatus()
            discoverControllerServices(on: peripheral)
            scheduleReconnectCheck(after: reconnectCheckDelay(8))
            return
        }

        if let peripheral, peripheral.state == .disconnecting {
            connectionState = "Reconnecting"
            updateProximityUnlockStatus()
            scheduleReconnectCheck(after: reconnectCheckDelay(8))
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
        guard region.identifier == doorUnlockerLockZoneRegionIdentifier else { return }

        Task { @MainActor in
            updateLockZoneContainment(from: .inside)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        guard region.identifier == doorUnlockerLockZoneRegionIdentifier else { return }

        Task { @MainActor in
            updateLockZoneContainment(from: .outside)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didDetermineState state: CLRegionState, for region: CLRegion) {
        guard region.identifier == doorUnlockerLockZoneRegionIdentifier else { return }

        Task { @MainActor in
            updateLockZoneContainment(from: state)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        guard region?.identifier == doorUnlockerLockZoneRegionIdentifier else { return }

        Task { @MainActor in
            lockZoneStatus = "Zone monitor off"
        }
    }
}

extension DoorUnlockerController: DoorFirmwareDfuManagerDelegate {
    func firmwareDfuManagerDidUpdate(status: String, progress: Int?) {
        firmwareUpdateStatus = status
        firmwareUpdateProgress = progress
    }

    func firmwareDfuManagerDidFinish() {
        cancelFirmwareUpdateSuccessReset()
        firmwareUpdateStatus = "Update complete. Verifying..."
        firmwareUpdateProgress = 100
        isFirmwareUpdateRunning = false
        firmwareUpdateEntryCommandSent = false
#if DEBUG
        if debugExpectedFirmwareVersion != nil {
            debugFirmwareAwaitingPostDfuVerification = true
            debugFirmwareVerifiedNotificationPosted = false
            recordStartupTelemetry("debug_firmware_waiting_wireless_verify", once: false)
        }
#endif
        firmwareDfuStartFallbackTask?.cancel()
        firmwareDfuStartFallbackTask = nil
        reconnectTimer?.invalidate()
        clearDiscoveredControllerCharacteristics()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            await MainActor.run {
                self?.scan()
                self?.scheduleStateSnapshotFallbackRead(delay: .milliseconds(700))
            }
        }
    }

    func firmwareDfuManagerDidFail(_ message: String) {
        cancelFirmwareUpdateSuccessReset()
        firmwareUpdateStatus = "Firmware update failed"
        firmwareUpdateProgress = nil
        isFirmwareUpdateRunning = false
        pendingFirmwareUpdatePackageURL = nil
        firmwareUpdateEntryCommandSent = false
#if DEBUG
        debugFirmwareAwaitingPostDfuVerification = false
        debugFirmwareVerifiedNotificationPosted = false
#endif
        firmwareDfuStartFallbackTask?.cancel()
        firmwareDfuStartFallbackTask = nil
        lastError = message
        scan()
    }
}

extension DoorUnlockerController: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            switch central.state {
            case .poweredOn:
#if DEBUG
                recordStartupTelemetry("bluetooth_powered_on")
#endif
                bluetoothState = "On"
                if isSecureCommandWriteReady {
#if DEBUG
                    recordStartupTelemetry("powered_on_ready_skip_scan")
#endif
                    updateProximityUnlockStatus()
                    if isReady, !isDoorCommandReady {
#if DEBUG
                        recordStartupTelemetry("powered_on_nonce_nudge")
#endif
                        requestFreshSecureControlNonce()
                    }
                    return
                }
                if proximityUnlockArmedAt != nil {
                    beginProximityUnlockBackgroundTask()
                    accelerateProximityUnlockReconnectIfNeeded()
                } else {
                    scan()
                }
            case .poweredOff, .unauthorized, .unsupported, .resetting, .unknown:
                updateBluetoothAvailabilityState(central.state)
            @unknown default:
                updateBluetoothAvailabilityState(central.state)
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
#if DEBUG
            recordStartupTelemetry("central_restored")
#endif
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
#if DEBUG
            recordStartupTelemetry("peripheral_discovered", details: "rssi=\(RSSI.intValue)")
#endif
            connect(to: peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            guard isCurrentPeripheral(peripheral) else {
                central.cancelPeripheralConnection(peripheral)
                return
            }

            if proximityUnlockArmedAt != nil {
                beginProximityUnlockBackgroundTask()
            }
#if DEBUG
            recordStartupTelemetry("peripheral_connected")
#endif
            reconnectTimer?.invalidate()
            knownPeripheralAssistScanTask?.cancel()
            knownPeripheralAssistScanTask = nil
            stopControllerScan()
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
            guard isCurrentPeripheral(peripheral) else { return }

            connectionState = "Disconnected"
            connectedDeviceCount = 0
            connectedDevices = []
            self.peripheral = nil
            lastError = error?.localizedDescription ?? "Connect failed"
            if isKnownOutsideLockZone {
                armProximityUnlockIfOutsideAndDisconnected()
            } else {
                updateProximityUnlockStatus()
            }
            scheduleReconnectCheck(after: Self.fastKnownControllerRetryDelay)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            guard isCurrentPeripheral(peripheral) else { return }

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
                lastError = error.localizedDescription
            }
            if isFirmwareUpdateRunning {
                connectionState = "Updating firmware"
                updateProximityUnlockStatus()
                return
            }
            if shouldCheckProximityUnlock {
                beginProximityUnlockAwayCheck()
                startScan()
            } else {
                clearProximityUnlockArming()
                updateProximityUnlockStatus()
                scheduleReconnectCheck(after: Self.fastKnownControllerRetryDelay)
            }
        }
    }
}

extension DoorUnlockerController: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            guard isCurrentPeripheral(peripheral) else { return }

            if let error {
                lastError = error.localizedDescription
                scheduleReconnectCheck(after: Self.fastKnownControllerRetryDelay)
                return
            }

            let doorServices = peripheral.services?.filter { $0.uuid == serviceUUID } ?? []
            guard !doorServices.isEmpty else {
                lastError = "Door service not found"
                scheduleReconnectCheck(after: Self.fastKnownControllerRetryDelay)
                return
            }

#if DEBUG
            recordStartupTelemetry("services_discovered")
#endif
            discoverControllerServices(on: peripheral)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        Task { @MainActor in
            guard isCurrentPeripheral(peripheral) else { return }

            if let error {
                lastError = error.localizedDescription
                scheduleReconnectCheck(after: Self.fastKnownControllerRetryDelay)
                return
            }

            applyControllerCharacteristics(service.characteristics ?? [], on: peripheral)
#if DEBUG
            recordStartupTelemetry("characteristics_discovered")
#endif

            if !finishConnectionIfReady() {
                if hasPendingDoorCharacteristicDiscovery(on: peripheral) {
                    scheduleReconnectCheck(after: reconnectCheckDelay(6))
                    return
                }

                lastError = "Required controller characteristic not found"
                central?.cancelPeripheralConnection(peripheral)
                scheduleReconnectCheck(after: Self.fastKnownControllerRetryDelay)
            }
        }
    }

    private func sendPendingSystemCommandIfReady() {
        guard isReady, fastCommandNonce != nil else { return }

        if sendQueuedControllerSettingIfReady() {
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

    @discardableResult
    private func sendQueuedControllerSettingIfReady() -> Bool {
        guard isReady, fastCommandNonce != nil else { return false }

        if let commandText = queuedPairingAdminCommand {
            queuedPairingAdminCommand = nil
            sendPairingAdminCommand(commandText)
            return true
        }

        if let seconds = queuedAutoLockTimeoutSeconds {
            queuedAutoLockTimeoutSeconds = nil
            autoLockSeconds = seconds
            applyAutoLockTimeout()
            return true
        }

        if let angles = queuedServoAngles {
            queuedServoAngles = nil
            servoLockAngle = angles.lockAngle
            servoUnlockAngle = angles.unlockAngle
            pendingServoAngles = angles
            applyServoAngles()
            return true
        }

        return false
    }

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

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor in
            guard isCurrentPeripheral(peripheral) else { return }

            if let error {
                if (characteristic.uuid != stateUUID && characteristic.uuid != controlUUID) || !isReadNotPermitted(error) {
                    lastError = error.localizedDescription
                }
                return
            }

            guard let data = characteristic.value else { return }
            let rawState = String(data: data, encoding: .utf8) ?? "unknown"
            if characteristic.uuid == controlUUID {
                controlUpdateGeneration += 1
                controlNonceRecoveryTask?.cancel()
                controlNonceRecoveryTask = nil

                if let nonce = DoorControllerStateParser.fastCommandNonce(from: rawState) {
                    applyFastCommandNonce(nonce)
                    return
                }

                if let rejectReason = DoorControllerStateParser.fastCommandRejectReason(from: rawState) {
                    handleFastCommandReject(reason: rejectReason)
                    updatePairingState(from: rejectReason == "unpaired" ? "unpaired" : "paired")
                    return
                }

                if let connections = DoorControllerStateParser.connectedDevices(from: rawState) {
                    connectedDeviceCount = connections.count
                    maximumConnectedDeviceCount = connections.max
                    connectedDevices = connections.devices
                    if pairingState == "Unknown" {
                        promoteKnownControllerPairingIfNeeded()
                    }
                    return
                }

                return
            }

            guard characteristic.uuid == stateUUID else { return }
            stateUpdateGeneration += 1
            stateSnapshotFallbackTask?.cancel()
            stateSnapshotFallbackTask = nil

            if let applying = DoorControllerStateParser.settingApplying(from: rawState) {
                applyRemoteSettingApplying(kind: applying.kind, value: applying.value)
                updatePairingState(from: "paired")
                return
            }

            if let controllerLockName = DoorControllerStateParser.lockName(from: rawState) {
                applyControllerLockName(controllerLockName)
                updatePairingState(from: "paired")
                return
            }

            if let controllerServoAngles = DoorControllerStateParser.servoAngles(from: rawState) {
                applyControllerServoAngles(controllerServoAngles)
                updatePairingState(from: "paired")
                return
            }

            if let controllerLastUnlock = DoorControllerStateParser.lastUnlockRecord(from: rawState) {
                applyControllerLastUnlock(controllerLastUnlock)
                hasRequestedControllerLastUnlock = true
                updatePairingState(from: "paired")
                return
            }

            if let controllerFirmwareVersion = DoorControllerStateParser.firmwareVersion(from: rawState) {
                firmwareVersion = controllerFirmwareVersion
                UserDefaults.standard.set(controllerFirmwareVersion, forKey: Self.cachedFirmwareVersionKey)
                firmwareVersionSnapshotRetryTask?.cancel()
                firmwareVersionSnapshotRetryTask = nil
#if DEBUG
                handleDebugFirmwareVersionVerification(controllerFirmwareVersion)
#endif
                if firmwareUpdateStatus == "Update complete. Verifying..." {
                    firmwareUpdateStatus = "Update finished. Controller is on \(controllerFirmwareVersion)."
                    firmwareUpdateProgress = 100
                    lastError = nil
                    finishFirmwareUpdateLiveActivity(version: controllerFirmwareVersion)
                    notifyFirmwareUpdateFinished(version: controllerFirmwareVersion)
                    scheduleFirmwareUpdateSuccessReset()
                }
                updatePairingState(from: "paired")
                return
            }

            if let updateState = DoorControllerStateParser.firmwareUpdateState(from: rawState) {
                if updateState == "ota_dfu" {
                    firmwareUpdateStatus = "Controller entering update mode"
                    beginPendingFirmwareDfuUploadIfNeeded()
                }
                updatePairingState(from: "paired")
                return
            }

            if let connections = DoorControllerStateParser.connectedDevices(from: rawState) {
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
                return
            }

            if parsedState.state == "paired" {
                clearRemoteSettingApplying()
                updatePairingState(from: parsedState.state)
                confirmDeviceDisplayNameSyncIfNeeded()
                syncLockNameIfReady()
                syncDeviceDisplayNameIfReady()
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
            runProximityUnlockIfReady()
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard error == nil else { return }

        Task { @MainActor in
            guard isCurrentPeripheral(peripheral) else { return }

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
            guard isCurrentPeripheral(peripheral) else { return }

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
                if case .firmwareUpdate = commandWriteIntent {
#if DEBUG
                    recordStartupTelemetry("firmware_write_failed", details: error.localizedDescription, once: false)
#endif
                    pendingFirmwareUpdatePackageURL = nil
                    firmwareUpdateEntryCommandSent = false
                    firmwareDfuStartFallbackTask?.cancel()
                    firmwareDfuStartFallbackTask = nil
                    firmwareUpdateStatus = "Firmware update request failed"
                    firmwareUpdateProgress = nil
                    isFirmwareUpdateRunning = false
                }
                if case .linkAuthentication = commandWriteIntent {
                    linkAuthenticationInFlight = false
                    hasAuthenticatedCurrentLink = false
                }
                if case .pairingAdmin(let commandText) = commandWriteIntent {
                    queuedPairingAdminCommand = commandText
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
                autoLockStatus = "Setting..."
                if isUnlocked {
                    publishWidgetState(servoState, resetAutoLockDeadline: true)
                }
                readStateIfPermitted()
            }

            if case .deviceDisplayName(let name) = commandWriteIntent,
               sentDeviceDisplayName == name {
                deviceDisplayNameStatus = "Setting..."
                readStateIfPermitted()
            }

            if case .lockName(let name) = commandWriteIntent,
               sentLockName == name {
                lockNameStatus = "Setting..."
                readStateIfPermitted()
            }

            if case .servoAngles(let angles) = commandWriteIntent,
               sentServoAngles == angles {
                servoAnglesStatus = "Setting..."
                readStateIfPermitted()
            }

            if case .firmwareUpdate = commandWriteIntent {
#if DEBUG
                recordStartupTelemetry("firmware_write_acknowledged", once: false)
#endif
                firmwareUpdateStatus = "Waiting for controller update mode"
                scheduleFirmwareDfuStartFallback()
                return
            }

            if case .linkAuthentication = commandWriteIntent {
                linkAuthenticationInFlight = false
                hasAuthenticatedCurrentLink = true
#if DEBUG
                recordStartupTelemetry("door_command_usable", details: "link_authenticated")
#endif
            }

            if case .pairingAdmin(let commandText) = commandWriteIntent {
                if commandText.hasPrefix("PAIR_APPROVE:") || commandText == "PAIR_REJECT" {
                    pairingAdminApprovalCode = ""
                }
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
              !hasRejectedCurrentSecurePairing,
              commandCharacteristic != nil,
              pairingCharacteristic != nil,
              peripheral?.state == .connected else {
            return
        }

        knownPairingFallbackTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
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
              !hasRejectedCurrentSecurePairing,
              commandCharacteristic != nil,
              pairingCharacteristic != nil,
              peripheral?.state == .connected else {
            return false
        }

        updatePairingState(from: "paired")
        sendPendingSystemCommandIfReady()
        syncLockNameIfReady()
        syncDeviceDisplayNameIfReady()
        return true
    }

    private func updatePairingState(from state: String) {
        switch state {
        case "pairing_enabled":
            knownPairingFallbackTask?.cancel()
            knownPairingFallbackTask = nil
            hasRejectedCurrentSecurePairing = false
            pairingState = "Pairing enabled"
            pairingApprovalCode = nil
            pairingAdminApprovalCode = ""
        case "pairing_pending":
            knownPairingFallbackTask?.cancel()
            knownPairingFallbackTask = nil
            hasRejectedCurrentSecurePairing = false
            let isCurrentDevicePairing = pairingState == "Pairing" || pairingApprovalCode != nil
            pairingState = "Pairing pending"
            if isCurrentDevicePairing && pairingApprovalCode == nil {
                pairingApprovalCode = try? DoorCommandAuthenticator.pairingApprovalCode()
            } else if !isCurrentDevicePairing {
                pairingApprovalCode = nil
            }
        case "pairing_locked", "unpaired":
            knownPairingFallbackTask?.cancel()
            knownPairingFallbackTask = nil
            pairingState = "Pairing locked"
            pairingApprovalCode = nil
            pairingAdminApprovalCode = ""
            setKnownPairedController(false)
            invalidatePreparedFastDoorCommandPayloads(clearNonce: true)
        case "paired":
            knownPairingFallbackTask?.cancel()
            knownPairingFallbackTask = nil
            hasRejectedCurrentSecurePairing = false
            pairingState = "Paired"
            setKnownPairedController(true)
            pairingApprovalCode = nil
            pairingAdminApprovalCode = ""
        case "locked", "unlocked", "locking", "unlocking", "timeout_set":
            guard !hasRejectedCurrentSecurePairing else {
                break
            }
            knownPairingFallbackTask?.cancel()
            knownPairingFallbackTask = nil
            pairingState = "Paired"
            setKnownPairedController(true)
        default:
            break
        }

        if !isSecureCommandWriteReady || !hasTrustedPairingForSecureCommand {
            invalidatePreparedFastDoorCommandPayloads(clearNonce: true)
        }

        if isReady, !isDoorCommandReady {
            startSecureLinkWatchdogIfNeeded()
        }

        pairFromInviteIfReady()
    }
}
