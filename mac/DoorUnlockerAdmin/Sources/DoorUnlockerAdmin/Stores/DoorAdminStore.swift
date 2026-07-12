import CoreBluetooth
import DoorUnlockerCore
import DoorUnlockerDFU
import DoorUnlockerShared
import Foundation
import os

enum DoorAdminError: LocalizedError {
    case noPortSelected
    case notConnected
    case noDeviceSelected
    case invalidController

    var errorDescription: String? {
        switch self {
        case .noPortSelected:
            return "Select a USB serial port first."
        case .notConnected:
            return "Connect to the controller first."
        case .noDeviceSelected:
            return "Select a paired device first."
        case .invalidController:
            return "The USB device did not return a valid Door Unlocker status response."
        }
    }
}

actor SerialTransactionGate {
    func transact(
        connection: SerialPortConnection,
        command: String,
        until markers: Set<String>,
        timeout: TimeInterval
    ) throws -> [String] {
        try connection.transact(command, until: markers, timeout: timeout)
    }
}

@MainActor
final class DoorAdminStore: NSObject, ObservableObject {
    let firmwareLog = Logger(subsystem: DoorLocalCommandBridge.appBundleIdentifier, category: "FirmwareUpdate")
    let runtimeLog = Logger(subsystem: DoorLocalCommandBridge.appBundleIdentifier, category: "StartupTiming")

    @Published var lockName = DoorAdminStore.loadLockName()
    @Published var lockNameStatus = "Controller name"
    @Published var ports: [SerialPortCandidate] = []
    @Published var selectedPortID: String?
    @Published var isConnected = false
    @Published var isUSBControllerValidated = false
    @Published var bluetoothState = "Starting" {
        didSet { recordRuntimeStateChange("bluetooth_state", from: oldValue, to: bluetoothState) }
    }
    @Published var wirelessConnectionState = "Starting" {
        didSet { recordRuntimeStateChange("wireless_state", from: oldValue, to: wirelessConnectionState) }
    }
    @Published var wirelessPairingState = "Unknown" {
        didSet { recordRuntimeStateChange("pairing_state", from: oldValue, to: wirelessPairingState) }
    }
    @Published var isBusy = false
    @Published var status = DoorAdminStore.loadCachedStatus()
    @Published var hasCurrentControllerSnapshot = false
    @Published var hasCurrentConnectionRoster = false
    @Published var lastControllerActivityAt: Date?
    @Published var controllerBootSessionIdentifier: String?
    @Published var controllerHealthStatus = "unknown"
    @Published var pairedDevices: [PairedDevice] = []
    @Published var selectedDeviceID: PairedDevice.ID?
    @Published var approvalCode = ""
    @Published var message = DoorAdminStore.cachedStartupMessage()
    @Published var autoLockStatus = "Ready"
    @Published var servoAnglesStatus = "Controller set"
    @Published var logLines: [String] = []
    @Published var localSettingApplyKind: String?
    @Published var remoteSettingApplyKind: String?
    @Published var remoteSettingApplyValue: String?
    @Published var firmwareUpdateStatus = "Ready"
    @Published var firmwareUpdateProgress: Int?
    @Published var isFirmwareUpdateRunning = false
    @Published var lastError: String?
    @Published var runtimeTelemetryEntries: [RuntimeTelemetryEntry] = []

    var isChangingDoorState: Bool {
        DoorControlPresentationPolicy.isChangingState(status.bleState)
    }

    var isDoorCommandQueued: Bool {
        (pendingWirelessPredictedCommand != nil || fastDoorCommandInFlight != nil) && !isChangingDoorState
    }

    var visibleLastError: String? {
        guard let lastError else { return nil }

        if shouldHideTransientStartupError(lastError) {
            return nil
        }

        return lastError
    }

    var isApplyingControllerSetting: Bool {
        autoLockApplyTask != nil ||
            pendingAutoLockSeconds != nil ||
            inFlightAutoLockSeconds != nil ||
            lockNameApplyTask != nil ||
            pendingLockName != nil ||
            inFlightLockName != nil ||
            servoAnglesApplyTask != nil ||
            pendingServoAngles != nil ||
            inFlightServoAngles != nil ||
            localSettingApplyKind != nil ||
            remoteSettingApplyKind != nil
    }

    var controllerSettingApplyTitle: String {
        if let localSettingApplyKind {
            return ControllerSettingFormatter.title(for: localSettingApplyKind, value: settingApplyValue(for: localSettingApplyKind))
        }

        if let value = pendingLockName ?? inFlightLockName {
            return ControllerSettingFormatter.title(for: "lock_name", value: ControllerSettingFormatter.shortValue(value))
        }

        if servoAnglesApplyTask != nil || pendingServoAngles != nil || inFlightServoAngles != nil {
            let angles = pendingServoAngles ?? inFlightServoAngles ?? status.servoAngles
            return ControllerSettingFormatter.title(for: "servo_angles", value: ControllerSettingFormatter.servoAnglesValue(angles))
        }

        if autoLockApplyTask != nil || pendingAutoLockSeconds != nil || inFlightAutoLockSeconds != nil {
            let seconds = pendingAutoLockSeconds ?? inFlightAutoLockSeconds ?? status.autoLockSeconds
            return ControllerSettingFormatter.title(for: "timeout", value: "\(seconds)s")
        }

        if let remoteSettingApplyKind {
            return ControllerSettingFormatter.title(
                for: remoteSettingApplyKind,
                value: ControllerSettingFormatter.displayValue(for: remoteSettingApplyKind, rawValue: remoteSettingApplyValue)
            )
        }

        return "Updating controller"
    }

    func settingApplyValue(for kind: String) -> String? {
        switch kind {
        case "lock_name":
            return ControllerSettingFormatter.shortValue(pendingLockName ?? inFlightLockName ?? lockName)
        case "servo_angles":
            return ControllerSettingFormatter.servoAnglesValue(pendingServoAngles ?? inFlightServoAngles ?? status.servoAngles)
        case "timeout":
            return "\(pendingAutoLockSeconds ?? inFlightAutoLockSeconds ?? status.autoLockSeconds)s"
        default:
            return nil
        }
    }

    static func isBluetoothEncryptionError(_ error: Error?) -> Bool {
        guard let description = error?.localizedDescription.lowercased() else { return false }
        return description.contains("encrypt") || description.contains("encryption")
    }

    var connection: SerialPortConnection?
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
    let serialGate = SerialTransactionGate()
    var syncTask: Task<Void, Never>?
    var startupHousekeepingTask: Task<Void, Never>?
    var usbStartupSyncTask: Task<Void, Never>?
    var autoLockApplyTask: Task<Void, Never>?
    var lockNameApplyTask: Task<Void, Never>?
    var servoAnglesApplyTask: Task<Void, Never>?
    var pendingAutoLockSeconds: Int?
    var inFlightAutoLockSeconds: Int?
    var pendingLockName: String?
    var inFlightLockName: String?
    var pendingServoAngles: ServoAngles?
    var inFlightServoAngles: ServoAngles?
    var controllerSettingConfirmation = DoorControllerSettingConfirmationState()
    var inFlightControllerSetting: ControllerSettingOperation? {
        controllerSettingConfirmation.operation
    }
    var controllerSettingConfirmationTask: Task<Void, Never>?
    var isSilentStatusSyncInFlight = false
    var isUSBConnectInFlight = false
    var hasConfirmedExpiredAutoLockDeadline = false
    var hasTrustedMacController = UserDefaults.standard.bool(forKey: DoorAdminStore.trustedMacControllerKey)
    var hasRejectedCurrentSecurePairing = false
    var lastUSBStatusSyncAt: Date?
    var lastWirelessStateSyncAt: Date?
    var lastPairedDevicesSyncAt: Date?
    var lastUSBDiscoveryAt: Date?
    var didTrustMacDuringUSBSession = false
    var pendingWirelessCommandText: String?
    var pendingWirelessPredictedCommand: Command?
    var pendingWirelessCommandIntent: WirelessCommandWriteIntent?
    var fastDoorCommandInFlight: Command?
    var fastDoorCommandPreviousStatus: ControllerStatus?
    var pendingLocalDoorCommand: Command?
    var controllerFreshness = DoorControllerFreshnessTracker()
    var fastCommandNonce: Data?
    var lastConsumedFastCommandNonce: Data?
    var preparedFastDoorCommandPayloads: [Command: DoorCommandAuthenticator.SignedFastCommandPayload] = [:]
    var preparedFastDoorCommandTask: Task<Void, Never>?
    var preparedFastDoorCommandGeneration = 0
    var remoteSettingApplyTask: Task<Void, Never>?
    var wirelessReconnectTask: Task<Void, Never>?
    var wirelessIdleDisconnectTask: Task<Void, Never>?
    var wirelessKnownPeripheralFallbackTask: Task<Void, Never>?
    var wirelessStateSnapshotFallbackTask: Task<Void, Never>?
    var wirelessStateSnapshotRequestGate = DoorSingleFlightRequestGate()
    var wirelessStateSnapshotRequestTimeoutTask: Task<Void, Never>?
    var wirelessFirmwareVersionSnapshotRetryTask: Task<Void, Never>?
    var hasCurrentFirmwareVersionSnapshot = false
    var wirelessStateUpdateGeneration = 0
    var wirelessControlNonceRecoveryTask: Task<Void, Never>?
    var secureLinkWatchdogTask: Task<Void, Never>?
    var queuedWirelessCommandNonceRequestCount = 0
    var wirelessDoorCommandTransportRecoveryTask: Task<Void, Never>?
    var wirelessDoorCommandConfirmationTask: Task<Void, Never>?
    var wirelessControlUpdateGeneration = 0
    var wirelessControlNonceRequestGate = DoorSingleFlightRequestGate()
    var wirelessControlNonceRequestTimeoutTask: Task<Void, Never>?
    var wirelessControllerNonceHandoffGate = DoorSingleFlightRequestGate()
    var wirelessControllerNonceHandoffTimeoutTask: Task<Void, Never>?
    var hasAuthenticatedCurrentWirelessLink = false
    var wirelessLinkAuthenticationInFlight = false
    var wirelessLinkAuthenticationAttemptCount = 0
    var wirelessLinkAuthenticationTimeoutTask: Task<Void, Never>?
    var activeWirelessScanAllowsDuplicates: Bool?
    var pendingWirelessWriteIntents: [WirelessCommandWriteIntent] = []
    var firmwareUpdateWatchdogTask: Task<Void, Never>?
    var firmwareDfuStartFallbackTask: Task<Void, Never>?
    var firmwareUpdateRecoveryRetryTask: Task<Void, Never>?
    lazy var firmwareDfuManager = DoorFirmwareDfuManager(
        delegate: self,
        logSubsystem: "io.github.bt1142msstate.DoorUnlockerAdmin",
        queueLabel: "io.github.bt1142msstate.DoorUnlockerAdmin.dfu"
    )
    var pendingFirmwareUpdatePackageURL: URL?
    var firmwareUpdateEntryCommandSent = false
    var expectedFirmwareVerificationVersion: String?
    var isAwaitingPostDfuFirmwareVerification = false
    var didPostFirmwareVerificationNotification = false
    var wirelessReconnectAttempt = 0
    var isWirelessStateNotificationEnabled = false
    let runtimeTelemetryStartedAt = ProcessInfo.processInfo.systemUptime
    var runtimeTelemetryEvents: Set<String> = []

    override init() {
        super.init()
        recordRuntimeTelemetry("store_init")
        Task.detached(priority: .userInitiated) {
            DoorCommandAuthenticator.prewarm()
        }
        scheduleStartupHousekeeping()
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleLocalCommandNotification(_:)),
            name: DoorLocalCommandBridge.notificationName,
            object: DoorLocalCommandBridge.sender
        )
        // Bluetooth startup is independent of serial discovery and should begin
        // immediately. USB remains the preferred transport once discovered.
        ensureBluetoothCentral()
        refreshPorts()
        startStateSyncLoop()
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            await MainActor.run {
                self?.resumeInterruptedFirmwareUpdateIfNeeded()
            }
        }
    }

    deinit {
        syncTask?.cancel()
        startupHousekeepingTask?.cancel()
        usbStartupSyncTask?.cancel()
        autoLockApplyTask?.cancel()
        lockNameApplyTask?.cancel()
        servoAnglesApplyTask?.cancel()
        controllerSettingConfirmationTask?.cancel()
        wirelessReconnectTask?.cancel()
        wirelessIdleDisconnectTask?.cancel()
        wirelessKnownPeripheralFallbackTask?.cancel()
        wirelessStateSnapshotFallbackTask?.cancel()
        wirelessFirmwareVersionSnapshotRetryTask?.cancel()
        wirelessControlNonceRecoveryTask?.cancel()
        wirelessControlNonceRequestTimeoutTask?.cancel()
        wirelessLinkAuthenticationTimeoutTask?.cancel()
        secureLinkWatchdogTask?.cancel()
        firmwareUpdateWatchdogTask?.cancel()
        firmwareUpdateRecoveryRetryTask?.cancel()
        DistributedNotificationCenter.default().removeObserver(self)
    }
}
