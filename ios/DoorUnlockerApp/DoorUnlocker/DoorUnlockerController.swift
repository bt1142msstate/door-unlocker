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

let doorUnlockerUnlockNotificationIdentifier = "DoorUnlockerUnlocked"
let doorUnlockerLockZoneRegionIdentifier = "DoorUnlockerLockZone"

@MainActor
final class DoorUnlockerController: NSObject, ObservableObject {
    @Published var bluetoothState = "Starting" {
        didSet {
            recordStartupStateChange("bluetooth_state", from: oldValue, to: bluetoothState)
        }
    }
    @Published var connectionState = "Starting" {
        didSet {
            recordStartupStateChange("connection_state", from: oldValue, to: connectionState)
        }
    }
    @Published var deviceName = "DoorUnlocker-XIAO-v4"
    @Published var connectedDeviceCount = 0
    @Published var maximumConnectedDeviceCount = 4
    @Published var connectedDevices: [ConnectedControllerDevice] = []
    @Published var hasCurrentConnectionRoster = false
    @Published var hasCurrentControllerSnapshot = false
    @Published var lastControllerActivityAt: Date?
    @Published var controllerBootSessionIdentifier: String?
    @Published var controllerHealthStatus = "unknown"
    @Published var servoState = DoorUnlockerController.storedInitialServoState()
    @Published var pairingState = "Unknown" {
        didSet {
            recordStartupStateChange("pairing_state", from: oldValue, to: pairingState)
        }
    }
    @Published var pairingApprovalCode: String?
    @Published var pairingAdminApprovalCode = ""
    @Published var requiresPairingRecovery = false
    @Published var activePairingInvite: PairingInvite?
    @Published var isAuthenticatingUnlock = false
    @Published var isAuthenticatingSettings = false
    @Published var areSettingsUnlocked = false
    @Published var autoLockSeconds = DoorUnlockerController.storedAutoLockSeconds()
    @Published var autoLockStatus = "Ready to set"
    @Published var autoLockRemainingSeconds: Int?
    @Published var servoLockAngle = DoorUnlockerController.defaultServoLockAngle
    @Published var servoUnlockAngle = DoorUnlockerController.defaultServoUnlockAngle
    @Published var servoAnglesStatus = "Controller set"
    @Published var lastUnlockAt = DoorUnlockerController.storedLastUnlockAt()
    @Published var lastUnlockDeviceIdentifier = DoorUnlockerController.storedLastUnlockDeviceIdentifier()
    @Published var lastUnlockDeviceName = DoorUnlockerController.storedLastUnlockDeviceName()
    @Published var lockName = DoorStatusStore.loadLockName()
    @Published var deviceDisplayName = DoorUnlockerController.storedDeviceDisplayName()
    @Published var lockNameStatus = "Shown in app and widget"
    @Published var deviceDisplayNameStatus = "Ready to sync"
    @Published var requiresUnlockAuthentication = UserDefaults.standard.bool(forKey: DoorUnlockerController.unlockAuthenticationKey)
    @Published var requiresHoldToUnlock = UserDefaults.standard.bool(forKey: DoorUnlockerController.unlockHoldRequirementKey)
    @Published var unlockHoldDurationSeconds = DoorUnlockerController.storedUnlockHoldDurationSeconds()
    @Published var unlockNotificationsEnabled = UserDefaults.standard.bool(forKey: DoorUnlockerController.unlockNotificationsKey)
    @Published var unlockNotificationStatus = "Checking"
    @Published var proximityUnlockEnabled = DoorUnlockerController.storedProximityUnlockEnabled()
    @Published var proximityUnlockRSSIThreshold = DoorUnlockerController.storedProximityUnlockRSSIThreshold()
    @Published var distanceUnit = DoorUnlockerController.storedDistanceUnit()
    @Published var proximityUnlockStatus = DoorUnlockerController.storedProximityUnlockEnabled() ? "Monitoring" : "Off"
    @Published var lockZoneCenter = DoorUnlockerController.storedLockZoneCenter()
    @Published var lockZoneRadiusMeters = DoorUnlockerController.storedLockZoneRadiusMeters()
    @Published var lockZoneUpdatedAt = DoorUnlockerController.storedLockZoneUpdatedAt()
    @Published var lockZoneStatus = DoorUnlockerController.storedLockZoneCenter() == nil ? "Unlock once to set" : "Ready"
    @Published var lockZoneUserLocation: CLLocationCoordinate2D?
    @Published var lockZoneUserAccuracyMeters: Double?
    @Published var lockZoneDistanceMeters: Double?
    @Published var lockZoneHeadingDegrees: Double?
    @Published var lockZoneHeadingAccuracyDegrees: Double?
    @Published var lockZoneCourseDegrees: Double?
    @Published var lockZoneCourseAccuracyDegrees: Double?
    @Published var lockZoneSpeedMetersPerSecond: Double?
    @Published var lockZoneBluetoothRSSI: Int?
    @Published var remoteSettingApplyKind: String?
    @Published var remoteSettingApplyValue: String?
    @Published var firmwareVersion = DoorUnlockerController.storedFirmwareVersion()
    @Published var firmwareUpdateStatus = "Ready" {
        didSet { syncFirmwareUpdateLiveActivityIfNeeded() }
    }
    @Published var firmwareUpdateProgress: Int? {
        didSet { syncFirmwareUpdateLiveActivityIfNeeded() }
    }
    @Published var firmwareUpdateEstimatedSecondsRemaining: Int? {
        didSet { syncFirmwareUpdateLiveActivityIfNeeded() }
    }
    @Published var isFirmwareUpdateRunning = false {
        didSet { syncFirmwareUpdateLiveActivityIfNeeded() }
    }
    @Published var startupTelemetryEntries: [StartupTelemetryEntry] = []
    @Published var lastError: String?

    let serviceUUID = CBUUID(string: "7A5A2000-2B8D-4C3E-94E7-0B3C0DDAAF10")
    let commandUUID = CBUUID(string: "7A5A2001-2B8D-4C3E-94E7-0B3C0DDAAF10")
    let stateUUID = CBUUID(string: "7A5A2002-2B8D-4C3E-94E7-0B3C0DDAAF10")
    let pairingUUID = CBUUID(string: "7A5A2003-2B8D-4C3E-94E7-0B3C0DDAAF10")
    let controlUUID = CBUUID(string: "7A5A2004-2B8D-4C3E-94E7-0B3C0DDAAF10")

    var central: CBCentralManager?
    var peripheral: CBPeripheral?
    var commandCharacteristic: CBCharacteristic?
    var stateCharacteristic: CBCharacteristic?
    var pairingCharacteristic: CBCharacteristic?
    var controlCharacteristic: CBCharacteristic?
    var reconnectTimer: Timer?
    var pendingSystemCommand: DoorSystemCommand?
    var pendingCommandWriteIntents: [CommandWriteIntent] = []
    var optimisticDoorCommand: Command?
    var optimisticDoorCommandOrigin: DoorCommandOrigin?
    var optimisticDoorCommandSentAt: Date?
    var optimisticDoorCommandAttempt = 0
    var optimisticDoorCommandAcknowledged = false
    var optimisticDoorPreviousServoState: String?
    var optimisticDoorCommandSessionGeneration: Int?
    var controllerSessionGeneration = 0
    var controllerFreshness = DoorControllerFreshnessTracker()
    var doorCommandRecoveryTask: Task<Void, Never>?
    var doorCommandTransportRecoveryTask: Task<Void, Never>?
    var pendingFreshNonceDoorCommand: PendingFreshNonceDoorCommand?
    var fastCommandNonce: Data?
    var lastConsumedFastCommandNonce: Data?
    var controlNonceRequestGate = DoorSingleFlightRequestGate()
    var controlNonceRequestTimeoutTask: Task<Void, Never>?
    var preparedFastDoorCommandPayloads: [Command: DoorCommandAuthenticator.SignedFastCommandPayload] = [:]
    var preparedFastDoorCommandTask: Task<Void, Never>?
    var preparedFastDoorCommandGeneration = 0
    var pendingAutoLockTimeoutSeconds: Int?
    var queuedAutoLockTimeoutSeconds: Int?
    var pendingServoAngles: ServoAngles?
    var queuedServoAngles: ServoAngles?
    var queuedPairingAdminCommand: String?
    var shouldPairFromInviteWhenReady = false
    var didSubmitPairingRecoveryRequest = false
    var controllerSettingConfirmationTask: Task<Void, Never>?
    var controllerSettingConfirmation = DoorControllerSettingConfirmationState()
    var inFlightControllerSetting: ControllerSettingOperation? {
        controllerSettingConfirmation.operation
    }
    var autoLockPredictionTask: Task<Void, Never>?
    var lockNameSyncTask: Task<Void, Never>?
    var deviceDisplayNameSyncTask: Task<Void, Never>?
    var pendingLockName: String?
    var sentLockName: String?
    var lastSyncedLockName: String?
    var hasRequestedControllerLockName = false
    var sentServoAngles: ServoAngles?
    var hasRequestedControllerServoAngles = false
    var hasRequestedControllerLastUnlock = false
    var pendingDeviceDisplayName: String?
    var sentDeviceDisplayName: String?
    var lastSyncedDeviceDisplayName: String?
    var knownPairingFallbackTask: Task<Void, Never>?
    var liveActivity: Activity<DoorUnlockerActivityAttributes>?
    var liveActivityCompletionTask: Task<Void, Never>?
    var isCompletingLiveActivity = false
    var liveActivityBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    var widgetReloadTask: Task<Void, Never>?
    var widgetReloadBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    var widgetReloadGeneration = 0
    var proximityUnlockBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    var forceQuitReliabilityWarningTask: Task<Void, Never>?
    var forceQuitReliabilityWarningBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    var startupHousekeepingTask: Task<Void, Never>?
    var proximityUnlockCandidateStartedAt: Date?
    var proximityUnlockArmTask: Task<Void, Never>?
    var proximityUnlockArmedAt = DoorUnlockerController.storedProximityUnlockArmedAt()
    var lastProximityUnlockAt: Date?
    var hasKnownPairedController = UserDefaults.standard.bool(forKey: DoorUnlockerController.knownPairedControllerKey)
    var remoteSettingApplyTask: Task<Void, Never>?
    var rssiReadTask: Task<Void, Never>?
    var secureLinkWatchdogTask: Task<Void, Never>?
    var queuedDoorCommandNonceRequestCount = 0
    var postReadySyncTask: Task<Void, Never>?
    var stateSnapshotFallbackTask: Task<Void, Never>?
    var startupCriticalSnapshotTask: Task<Void, Never>?
    var stateSnapshotRequestGate = DoorSingleFlightRequestGate()
    var stateSnapshotRequestTimeoutTask: Task<Void, Never>?
    var firmwareVersionSnapshotRetryTask: Task<Void, Never>?
    var hasCurrentFirmwareVersionSnapshot = false
    var stateUpdateGeneration = 0
    var controlNonceRecoveryTask: Task<Void, Never>?
    var controlUpdateGeneration = 0
    var controllerNonceHandoffGate = DoorSingleFlightRequestGate()
    var controllerNonceHandoffTimeoutTask: Task<Void, Never>?
    var restoredConnectionValidationTask: Task<Void, Never>?
    var restoredConnectionValidationSessionGeneration: Int?
    var hasAuthenticatedCurrentLink = false
    var linkAuthenticationInFlight = false
    var linkAuthenticationAttemptCount = 0
    var linkAuthenticationTimeoutTask: Task<Void, Never>?
    var knownPeripheralAssistScanTask: Task<Void, Never>?
    var activeScanAllowsDuplicates: Bool?
    var hasRejectedCurrentSecurePairing = false
    lazy var firmwareDfuManager = DoorFirmwareDfuManager(
        delegate: self,
        logSubsystem: "io.github.bt1142msstate.DoorUnlocker",
        queueLabel: "io.github.bt1142msstate.DoorUnlocker.dfu"
    )
    let firmwareLiveActivityCoordinator = DoorFirmwareLiveActivityCoordinator()
    var pendingFirmwareUpdatePackageURL: URL?
    var firmwareUpdateEntryCommandSent = false
    var firmwareDfuStartFallbackTask: Task<Void, Never>?
    var firmwareUpdateCompletionResetTask: Task<Void, Never>?
    var firmwareUpdateRecoveryRetryTask: Task<Void, Never>?
    var autoBundledFirmwareUpdateAttemptedVersion: String?
    var autoBundledFirmwareUpdateEvaluatedVersionPair: String?
    var didHandleDebugLaunchFirmwareUpdateArgument = false
#if DEBUG
    var debugExpectedFirmwareVersion: String?
    var debugFirmwareAwaitingPostDfuVerification = false
    var debugFirmwareVerifiedNotificationPosted = false
    let startupTelemetryStartedAt = ProcessInfo.processInfo.systemUptime
    var startupTelemetryEvents: Set<String> = []
    var warmLaunchTelemetryStartedAt: TimeInterval?
#endif
    let locationManager = CLLocationManager()
    var pendingLocationRequests: [LockZoneLocationRequest] = []
    var isKnownOutsideLockZone = UserDefaults.standard.bool(forKey: DoorUnlockerController.lockZoneOutsideKey)
    var latestLockZoneLocation: CLLocation?
    var isRequestingTemporaryFullAccuracy = false
    var isLockZoneLocationUpdating = false
    var isSignificantLocationMonitoringActive = false
    var settingsAuthenticationGeneration = 0

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
        if proximityUnlockArmedAt != nil {
            beginProximityUnlockBackgroundTask()
        }
        resumeInterruptedBundledFirmwareUpdateIfNeeded()
        updateProximityUnlockStatus()
        scheduleDeferredStartupHousekeeping()
    }

    deinit {
        startupHousekeepingTask?.cancel()
        stateSnapshotFallbackTask?.cancel()
        startupCriticalSnapshotTask?.cancel()
        stateSnapshotRequestTimeoutTask?.cancel()
        firmwareVersionSnapshotRetryTask?.cancel()
        firmwareUpdateRecoveryRetryTask?.cancel()
        controlNonceRecoveryTask?.cancel()
        controlNonceRequestTimeoutTask?.cancel()
        controllerNonceHandoffTimeoutTask?.cancel()
        linkAuthenticationTimeoutTask?.cancel()
        restoredConnectionValidationTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }
}
