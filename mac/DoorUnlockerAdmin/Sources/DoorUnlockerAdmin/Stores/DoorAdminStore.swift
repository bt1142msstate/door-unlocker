import CoreBluetooth
import DoorUnlockerCore
import Foundation
import os

enum DoorAdminError: LocalizedError {
    case noPortSelected
    case notConnected
    case noDeviceSelected

    var errorDescription: String? {
        switch self {
        case .noPortSelected:
            return "Select a USB serial port first."
        case .notConnected:
            return "Connect to the controller first."
        case .noDeviceSelected:
            return "Select a paired device first."
        }
    }
}

private actor SerialTransactionGate {
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
    private let firmwareLog = Logger(subsystem: DoorLocalCommandBridge.appBundleIdentifier, category: "FirmwareUpdate")
    private let runtimeLog = Logger(subsystem: DoorLocalCommandBridge.appBundleIdentifier, category: "StartupTiming")

    struct RuntimeTelemetryEntry: Identifiable, Equatable {
        let id = UUID()
        let elapsedMilliseconds: Int
        let event: String
        let details: String?

        var timeText: String {
            "\(elapsedMilliseconds)ms"
        }

        var title: String {
            switch event {
            case "store_init":
                return "Admin app started"
            case "central_created":
                return "Bluetooth manager created"
            case "bluetooth_powered_on":
                return "Bluetooth powered on"
            case "scan_requested":
                return "Scan requested"
            case "known_peripheral_retrieved":
                return "Saved controller found"
            case "connected_peripheral_retrieved":
                return "Connected controller reused"
            case "connect_start":
                return "Bluetooth connection started"
            case "peripheral_connected":
                return "Bluetooth connected"
            case "services_discovered":
                return "Services discovered"
            case "gatt_ready":
                return "Controller link ready"
            case "state_notify_enabled":
                return "State updates enabled"
            case "control_notify_enabled":
                return "Secure control updates enabled"
            case "secure_nonce_requested":
                return "Secure nonce requested"
            case "secure_nonce_received":
                return "Secure nonce received"
            case "door_command_usable":
                return "Door command usable"
            case "first_fast_payload_ready":
                return "Fast command prepared"
            case "wireless_command_sent":
                return "Wireless command sent"
            case "usb_auto_connect_start":
                return "USB-C auto-connect started"
            case "usb_ready":
                return "USB-C ready"
            case "usb_startup_sync_start":
                return "USB-C startup sync started"
            case "usb_startup_sync_done":
                return "USB-C startup sync finished"
            case "usb_command_start":
                return "USB-C command started"
            case "usb_command_done":
                return "USB-C command finished"
            case "bluetooth_state":
                return "Bluetooth state"
            case "wireless_state":
                return "Wireless state"
            case "pairing_state":
                return "Pairing state"
            case "status_state":
                return "Door state"
            default:
                return event
                    .replacingOccurrences(of: "_", with: " ")
                    .capitalized
            }
        }
    }

    enum Command: String {
        case unlock = "UNLOCK"
        case lock = "LOCK"

        var commandText: String {
            rawValue
        }

        var authenticatorFastCommand: DoorCommandAuthenticator.FastCommand {
            self == .unlock ? .unlock : .lock
        }
    }

    private enum WirelessCommandWriteIntent {
        case doorCommand
        case autoLockTimeout(Int)
        case lockName(String)
        case servoAngles(ServoAngles)
        case firmwareUpdate(URL)
        case generic
    }

    private struct LastUnlockRecord {
        let unlockedAt: Date?
        let deviceIdentifier: String?
        let deviceName: String?
    }

    static let defaultLockName = "My Lock"
    static let minimumAutoLockSeconds = 5
    static let maximumAutoLockSeconds = 120
    private static let lockNameKey = "DoorUnlockerAdminLockName"
    private static let cachedBleStateKey = "DoorUnlockerAdminCachedBleState"
    private static let cachedAutoLockSecondsKey = "DoorUnlockerAdminCachedAutoLockSeconds"
    private static let cachedLockAngleKey = "DoorUnlockerAdminCachedLockAngle"
    private static let cachedUnlockAngleKey = "DoorUnlockerAdminCachedUnlockAngle"
    private static let cachedPairedCountKey = "DoorUnlockerAdminCachedPairedCount"
    private static let cachedMaxPairsKey = "DoorUnlockerAdminCachedMaxPairs"
    private static let cachedMaxConnectionsKey = "DoorUnlockerAdminCachedMaxConnections"
    private static let cachedFirmwareVersionKey = "DoorUnlockerAdminCachedFirmwareVersion"
    private static let trustedMacControllerKey = "DoorUnlockerAdminTrustedMacController"
    private static let localSigningPublicKeyKey = "DoorUnlockerAdminLocalSigningPublicKey"
    private static let knownPeripheralIdentifierKey = "DoorUnlockerAdminKnownPeripheralIdentifier"
    private static let pairedDevicesSyncInterval: TimeInterval = 5
    private static let wirelessStatePollInterval: TimeInterval = 10
    private static let wirelessReconnectDelays: [TimeInterval] = [0.15, 0.45, 0.9, 1.8, 3.5]
    private static let wirelessEncryptionRecoveryDelay: TimeInterval = 3
    private static let knownPeripheralDiscoveryRetryDelay: TimeInterval = 0.15
    private static let usbStartupSyncGraceNanoseconds: UInt64 = 75_000_000
    private static let localUSBDeviceHandle = "usb-c-this-mac"
    private static let runtimeTraceWriter = DispatchQueue(label: "io.github.bt1142msstate.DoorUnlockerAdmin.runtimeTrace", qos: .utility)
    private static let runtimeTraceFileURL: URL = {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return baseURL
            .appendingPathComponent("DoorUnlockerAdmin", isDirectory: true)
            .appendingPathComponent("startup-timing.log")
    }()

    @Published private(set) var lockName = DoorAdminStore.loadLockName()
    @Published private(set) var lockNameStatus = "Controller name"
    @Published var ports: [SerialPortCandidate] = []
    @Published var selectedPortID: String?
    @Published private(set) var isConnected = false
    @Published private(set) var bluetoothState = "Starting" {
        didSet { recordRuntimeStateChange("bluetooth_state", from: oldValue, to: bluetoothState) }
    }
    @Published private(set) var wirelessConnectionState = "Starting" {
        didSet { recordRuntimeStateChange("wireless_state", from: oldValue, to: wirelessConnectionState) }
    }
    @Published private(set) var wirelessPairingState = "Unknown" {
        didSet { recordRuntimeStateChange("pairing_state", from: oldValue, to: wirelessPairingState) }
    }
    @Published private(set) var isBusy = false
    @Published private(set) var status = DoorAdminStore.loadCachedStatus()
    @Published private(set) var pairedDevices: [PairedDevice] = []
    @Published var selectedDeviceID: PairedDevice.ID?
    @Published var approvalCode = ""
    @Published private(set) var message = DoorAdminStore.cachedStartupMessage()
    @Published private(set) var autoLockStatus = "Ready"
    @Published private(set) var servoAnglesStatus = "Controller set"
    @Published private(set) var logLines: [String] = []
    @Published private(set) var localSettingApplyKind: String?
    @Published private(set) var remoteSettingApplyKind: String?
    @Published private(set) var remoteSettingApplyValue: String?
    @Published private(set) var firmwareUpdateStatus = "Ready"
    @Published private(set) var firmwareUpdateProgress: Int?
    @Published private(set) var isFirmwareUpdateRunning = false
    @Published var lastError: String?
    @Published private(set) var runtimeTelemetryEntries: [RuntimeTelemetryEntry] = []

    var isChangingDoorState: Bool {
        status.bleState == "locking" || status.bleState == "unlocking"
    }

    var isDoorCommandQueued: Bool {
        pendingWirelessPredictedCommand != nil && !isChangingDoorState
    }

    var queuedDoorCommandActionTitle: String? {
        guard let pendingWirelessPredictedCommand, !isChangingDoorState else {
            return nil
        }

        return pendingWirelessPredictedCommand == .unlock ? "Preparing unlock..." : "Preparing lock..."
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
            return Self.settingApplyTitle(for: localSettingApplyKind, value: settingApplyValue(for: localSettingApplyKind))
        }

        if let value = pendingLockName ?? inFlightLockName {
            return Self.settingApplyTitle(for: "lock_name", value: Self.shortSettingValue(value))
        }

        if servoAnglesApplyTask != nil || pendingServoAngles != nil || inFlightServoAngles != nil {
            let angles = pendingServoAngles ?? inFlightServoAngles ?? status.servoAngles
            return Self.settingApplyTitle(for: "servo_angles", value: Self.settingApplyValue(for: angles))
        }

        if autoLockApplyTask != nil || pendingAutoLockSeconds != nil || inFlightAutoLockSeconds != nil {
            let seconds = pendingAutoLockSeconds ?? inFlightAutoLockSeconds ?? status.autoLockSeconds
            return Self.settingApplyTitle(for: "timeout", value: "\(seconds)s")
        }

        if let remoteSettingApplyKind {
            return Self.settingApplyTitle(for: remoteSettingApplyKind, value: Self.displayValue(for: remoteSettingApplyKind, rawValue: remoteSettingApplyValue))
        }

        return "Updating controller"
    }

    private func settingApplyValue(for kind: String) -> String? {
        switch kind {
        case "lock_name":
            return Self.shortSettingValue(pendingLockName ?? inFlightLockName ?? lockName)
        case "servo_angles":
            return Self.settingApplyValue(for: pendingServoAngles ?? inFlightServoAngles ?? status.servoAngles)
        case "timeout":
            return "\(pendingAutoLockSeconds ?? inFlightAutoLockSeconds ?? status.autoLockSeconds)s"
        default:
            return nil
        }
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
            return "Updating controller"
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

    private static func shortSettingValue(_ value: String, maxLength: Int = 18) -> String? {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else { return nil }
        guard trimmedValue.count > maxLength else { return trimmedValue }

        let endIndex = trimmedValue.index(trimmedValue.startIndex, offsetBy: maxLength)
        return "\(trimmedValue[..<endIndex])..."
    }

    private static func isBluetoothEncryptionError(_ error: Error?) -> Bool {
        guard let description = error?.localizedDescription.lowercased() else { return false }
        return description.contains("encrypt") || description.contains("encryption")
    }

    private var connection: SerialPortConnection?
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
    private let serialGate = SerialTransactionGate()
    private var syncTask: Task<Void, Never>?
    private var startupHousekeepingTask: Task<Void, Never>?
    private var usbStartupSyncTask: Task<Void, Never>?
    private var autoLockApplyTask: Task<Void, Never>?
    private var lockNameApplyTask: Task<Void, Never>?
    private var servoAnglesApplyTask: Task<Void, Never>?
    private var pendingAutoLockSeconds: Int?
    private var inFlightAutoLockSeconds: Int?
    private var pendingLockName: String?
    private var inFlightLockName: String?
    private var pendingServoAngles: ServoAngles?
    private var inFlightServoAngles: ServoAngles?
    private var isSilentStatusSyncInFlight = false
    private var isUSBConnectInFlight = false
    private var hasConfirmedExpiredAutoLockDeadline = false
    private var hasTrustedMacController = UserDefaults.standard.bool(forKey: DoorAdminStore.trustedMacControllerKey)
    private var lastUSBStatusSyncAt: Date?
    private var lastWirelessStateSyncAt: Date?
    private var lastPairedDevicesSyncAt: Date?
    private var lastUSBDiscoveryAt: Date?
    private var didTrustMacDuringUSBSession = false
    private var pendingWirelessCommandText: String?
    private var pendingWirelessPredictedCommand: Command?
    private var pendingWirelessCommandIntent: WirelessCommandWriteIntent?
    private var fastDoorCommandInFlight: Command?
    private var fastCommandNonce: Data?
    private var preparedFastDoorCommandPayloads: [Command: DoorCommandAuthenticator.SignedFastCommandPayload] = [:]
    private var preparedFastDoorCommandTask: Task<Void, Never>?
    private var preparedFastDoorCommandGeneration = 0
    private var remoteSettingApplyTask: Task<Void, Never>?
    private var wirelessReconnectTask: Task<Void, Never>?
    private var wirelessIdleDisconnectTask: Task<Void, Never>?
    private var wirelessKnownPeripheralFallbackTask: Task<Void, Never>?
    private var wirelessStateSnapshotFallbackTask: Task<Void, Never>?
    private var wirelessStateUpdateGeneration = 0
    private var wirelessControlNonceRecoveryTask: Task<Void, Never>?
    private var secureLinkWatchdogTask: Task<Void, Never>?
    private var wirelessControlUpdateGeneration = 0
    private var activeWirelessScanAllowsDuplicates: Bool?
    private var queuedWirelessCommandDuringCurrentSend = false
    private var pendingWirelessWriteIntents: [WirelessCommandWriteIntent] = []
    private var firmwareUpdateWatchdogTask: Task<Void, Never>?
    private lazy var firmwareDfuManager = DoorFirmwareDfuManager(delegate: self)
    private var pendingFirmwareUpdatePackageURL: URL?
    private var firmwareUpdateEntryCommandSent = false
    private var wirelessReconnectAttempt = 0
    private var isWirelessStateNotificationEnabled = false
    private let runtimeTelemetryStartedAt = ProcessInfo.processInfo.systemUptime
    private var runtimeTelemetryEvents: Set<String> = []

    var selectedPort: SerialPortCandidate? {
        ports.first { $0.id == selectedPortID }
    }

    var selectedDevice: PairedDevice? {
        pairedDevices.first { $0.id == selectedDeviceID }
    }

    var autoLockRange: ClosedRange<Int> {
        Self.minimumAutoLockSeconds ... Self.maximumAutoLockSeconds
    }

    var servoAngleRange: ClosedRange<Int> {
        status.servoAngleRange
    }

    var isWirelessConnected: Bool {
        peripheral?.state == .connected
    }

    var isWirelessSessionActive: Bool {
        if let peripheral, peripheral.state == .connecting || peripheral.state == .connected {
            return true
        }
        return wirelessConnectionState == "Scanning"
    }

    private var isWirelessGattReady: Bool {
        peripheral?.state == .connected
            && commandCharacteristic != nil
            && stateCharacteristic != nil
            && pairingCharacteristic != nil
            && controlCharacteristic != nil
    }

    var isWirelessReady: Bool {
        isWirelessGattReady && hasTrustedMacController
    }

    var isWirelessDoorCommandReady: Bool {
        isWirelessReady && (fastCommandNonce != nil || !preparedFastDoorCommandPayloads.isEmpty)
    }

    private var canUseWirelessFallback: Bool {
        !isConnected && !isUSBConnectInFlight && hasTrustedMacController
    }

    private var hasKnownWirelessController: Bool {
        peripheral != nil || UserDefaults.standard.string(forKey: Self.knownPeripheralIdentifierKey) != nil
    }

    private var canQueueWirelessCommandForKnownController: Bool {
        guard !isConnected,
              !isUSBConnectInFlight,
              hasTrustedMacController else {
            return false
        }

        if isWirelessReady {
            return true
        }

        if central?.state == .poweredOn {
            return true
        }

        guard hasKnownWirelessController,
              bluetoothState == "Starting" || bluetoothState == "Unknown" else {
            return false
        }

        return central == nil || central?.state == .unknown || central?.state == .resetting
    }

    private var wirelessStopReason: String {
        isConnected || isUSBConnectInFlight ? "USB-C active" : "Idle"
    }

    private func shouldHideTransientStartupError(_ error: String) -> Bool {
        guard canSendDoorCommand || isDoorCommandQueued || isWirelessQueueReady else {
            return false
        }

        let normalizedError = error.lowercased()
        let transientFragments = [
            "not connected",
            "connection failed",
            "wirelessly",
            "required bluetooth characteristics were not found",
            "door service not found over bluetooth",
            "fresh secure command"
        ]

        return transientFragments.contains { normalizedError.contains($0) }
    }

    private static func currentEpochSeconds() -> UInt64 {
        UInt64(max(0, Date().timeIntervalSince1970.rounded(.down)))
    }

    private var localMacDeviceName: String {
        DoorDeviceNameNormalizer.normalized(Host.current().localizedName ?? "Mac", fallback: "Mac")
    }

    private var localUSBDeviceDisplayName: String {
        "\(localMacDeviceName) (USB-C)"
    }

    private var localUSBDevice: ConnectedControllerDevice {
        ConnectedControllerDevice(
            slot: 0,
            handle: Self.localUSBDeviceHandle,
            name: localUSBDeviceDisplayName,
            isTrustedName: true
        )
    }

    private static func appUnlockCommandText() -> String {
        let deviceName = DoorDeviceNameNormalizer.normalized(Host.current().localizedName ?? "Mac", fallback: "Mac")
        return "app unlock \(currentEpochSeconds()) \(deviceName)"
    }

    private static func appLockCommandText() -> String {
        "app lock \(currentEpochSeconds())"
    }

    var canSendDoorCommand: Bool {
        isConnected || isWirelessReady || canQueueWirelessCommandForKnownController
    }

    private var isWirelessQueueReady: Bool {
        canSendDoorCommand && !isConnected && !isWirelessReady
    }

    var displayedStatus: ControllerStatus {
        if isConnected || isUSBConnectInFlight {
            return statusIncludingLocalUSBConnection(status)
        }

        if isWirelessReady || isWirelessQueueReady {
            var nextStatus = statusRemovingLocalUSBConnection(status)
            nextStatus.connectedCount = max(nextStatus.connectedCount, 1)
            nextStatus.maxConnections = max(nextStatus.maxConnections, 4)
            return nextStatus
        }

        guard peripheral?.state == .connected else {
            return statusRemovingLocalUSBConnection(status)
        }

        var nextStatus = statusRemovingLocalUSBConnection(status)
        nextStatus.connectedCount = max(nextStatus.connectedCount, 1)
        nextStatus.maxConnections = max(nextStatus.maxConnections, 4)
        return nextStatus
    }

    var primaryConnectionTitle: String {
        if isConnected || isUSBConnectInFlight {
            return "USB-C"
        }
        if isWirelessReady {
            return "Wireless"
        }
        if isWirelessQueueReady {
            return "Wireless"
        }
        return "Disconnected"
    }

    var stateTitle: String {
        let title = status.stateTitle
        if title == "Unknown", canSendDoorCommand {
            return "Ready"
        }
        return title == "Unknown" ? "Disconnected" : title
    }

    var controllerStatusTitle: String {
        if status.hasPendingRequest {
            return "Pairing request"
        }
        if isUSBConnectInFlight && !isConnected {
            return "Opening USB-C"
        }
        if isConnected || isWirelessReady {
            return "Controller ready"
        }
        if isWirelessQueueReady {
            return "Ready for your click"
        }
        if bluetoothState != "On" {
            return "Bluetooth \(bluetoothState)"
        }
        return wirelessConnectionState
    }

    var controllerStatusDetail: String {
        if isWirelessQueueReady {
            return hasKnownWirelessController
                ? "Wireless will send securely as soon as the saved controller link opens"
                : "Wireless will send securely as soon as the trusted controller is found"
        }

        let status = displayedStatus
        return "Connection \(primaryConnectionTitle) - Connected \(status.connectedCount)/\(max(status.maxConnections, 4)) - Trusted \(status.pairedCount)/\(max(status.maxPairs, 4))"
    }

    var controllerStatusSymbol: String {
        if status.hasPendingRequest {
            return "person.badge.key.fill"
        }
        if isUSBConnectInFlight && !isConnected {
            return "cable.connector"
        }
        if isConnected || isWirelessReady {
            return "checkmark.circle.fill"
        }
        if isWirelessQueueReady {
            return "checkmark.circle.fill"
        }
        if bluetoothState != "On" {
            return "exclamationmark.triangle.fill"
        }
        return "antenna.radiowaves.left.and.right"
    }

    var connectionSummaryTitle: String {
        if isConnected {
            return "USB-C connected"
        }
        if isWirelessReady {
            return "Wireless ready"
        }
        if isWirelessQueueReady {
            return "Wireless ready"
        }
        if isWirelessGattReady {
            return "Wireless connected"
        }
        if bluetoothState != "On" {
            return "Bluetooth \(bluetoothState)"
        }
        return wirelessConnectionState
    }

    var connectionSummaryDetail: String {
        if isConnected {
            return "Admin commands and settings use USB-C. Other Bluetooth devices still appear in connected devices."
        }
        if isWirelessReady {
            return "Wireless is connected. The controller serializes commands from multiple trusted devices."
        }
        if isWirelessQueueReady {
            return hasKnownWirelessController
                ? "Commands can queue while the saved controller link opens."
                : "Commands can queue while the Mac scans for the trusted controller."
        }
        if isWirelessGattReady {
            return "Connect USB-C once to trust this Mac for secure wireless commands."
        }
        if bluetoothState != "On" {
            return "Turn Bluetooth on to use wireless control."
        }
        return "USB-C connects automatically when plugged in. Wireless connects on demand so the iPhone stays responsive."
    }

    var wirelessConnectionDisplayValue: String {
        if isWirelessReady || isWirelessQueueReady {
            return "Ready"
        }
        return wirelessConnectionState
    }

    var wirelessConnectionDisplaySymbol: String {
        if isConnected {
            return "pause.circle.fill"
        }
        if isWirelessReady || isWirelessQueueReady {
            return "checkmark.circle.fill"
        }
        return "antenna.radiowaves.left.and.right"
    }

    var isWirelessConnectionDisplayReady: Bool {
        isWirelessReady || isWirelessQueueReady
    }

    var connectedDevicesCountText: String {
        let status = displayedStatus
        return "\(status.connectedCount)/\(max(status.maxConnections, 4))"
    }

    var trustedDevicesCountText: String {
        let count = max(status.pairedCount, pairedDevices.count, hasTrustedMacController ? 1 : 0)
        let maximum = max(status.maxPairs, count, 4)
        return "\(count)/\(maximum)"
    }

    var connectedDevicesEmptyMessage: String {
        if isWirelessQueueReady && statusRemovingLocalUSBConnection(status).connectedDevices.isEmpty {
            return hasKnownWirelessController
                ? "Saved wireless link is ready. Active devices will appear after the controller link opens."
                : "Trusted wireless control is ready. Active devices will appear after the controller is found."
        }

        let status = displayedStatus
        return status.connectedCount > 0 ? "Connected devices are identifying." : "No devices are connected."
    }

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
        refreshPorts()
        if !isConnected && !isUSBConnectInFlight {
            ensureBluetoothCentral()
        }
        startStateSyncLoop()
    }

    private func recordRuntimeTelemetry(_ event: String, details: String? = nil, once: Bool = true) {
        if once, runtimeTelemetryEvents.contains(event) {
            return
        }

        if once {
            runtimeTelemetryEvents.insert(event)
        }

        let elapsedMilliseconds = Int(((ProcessInfo.processInfo.systemUptime - runtimeTelemetryStartedAt) * 1000).rounded())
        let entry = RuntimeTelemetryEntry(
            elapsedMilliseconds: elapsedMilliseconds,
            event: event,
            details: details
        )
        runtimeTelemetryEntries.append(entry)
        if runtimeTelemetryEntries.count > 80 {
            runtimeTelemetryEntries.removeFirst(runtimeTelemetryEntries.count - 80)
        }

        if let details, !details.isEmpty {
            runtimeLog.notice("\(elapsedMilliseconds, privacy: .public)ms \(event, privacy: .public) \(details, privacy: .public)")
            print("DUMacStartup \(elapsedMilliseconds)ms \(event) \(details)")
            persistRuntimeTelemetryLine("DUMacStartup \(elapsedMilliseconds)ms \(event) \(details)")
        } else {
            runtimeLog.notice("\(elapsedMilliseconds, privacy: .public)ms \(event, privacy: .public)")
            print("DUMacStartup \(elapsedMilliseconds)ms \(event)")
            persistRuntimeTelemetryLine("DUMacStartup \(elapsedMilliseconds)ms \(event)")
        }
    }

    private func recordRuntimeStateChange(_ event: String, from oldValue: String, to newValue: String) {
        guard oldValue != newValue else { return }
        recordRuntimeTelemetry(event, details: "\(oldValue) -> \(newValue)", once: false)
    }

    private func persistRuntimeTelemetryLine(_ line: String) {
        let url = Self.runtimeTraceFileURL
        Self.runtimeTraceWriter.async {
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(atPath: url.path, contents: nil)
                }

                let handle = try FileHandle(forWritingTo: url)
                try handle.seekToEnd()
                if let data = "\(Date().ISO8601Format()) \(line)\n".data(using: .utf8) {
                    try handle.write(contentsOf: data)
                }
                try handle.close()
            } catch {
                // Telemetry must never affect controller control.
            }
        }
    }

    private func scheduleStartupHousekeeping() {
        startupHousekeepingTask?.cancel()
        startupHousekeepingTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            let encodedPublicKey = await Task.detached(priority: .utility) {
                try? DoorCommandAuthenticator.publicKeyX963Representation().base64EncodedString()
            }.value
            await MainActor.run {
                self?.startupHousekeepingTask = nil
                self?.reconcileLocalSigningIdentityTrust(encodedPublicKey: encodedPublicKey)
            }
        }
    }

    private func reconcileLocalSigningIdentityTrust(encodedPublicKey: String?) {
        guard let encodedPublicKey else { return }
        let storedPublicKey = UserDefaults.standard.string(forKey: Self.localSigningPublicKeyKey)
        UserDefaults.standard.set(encodedPublicKey, forKey: Self.localSigningPublicKeyKey)

        guard storedPublicKey != encodedPublicKey else { return }

        if hasTrustedMacController {
            setTrustedMacController(false)
            wirelessPairingState = "USB-C trust needed"
            message = "Connect USB-C once to trust this Mac"
        }
    }

    deinit {
        syncTask?.cancel()
        startupHousekeepingTask?.cancel()
        usbStartupSyncTask?.cancel()
        autoLockApplyTask?.cancel()
        lockNameApplyTask?.cancel()
        servoAnglesApplyTask?.cancel()
        wirelessReconnectTask?.cancel()
        wirelessIdleDisconnectTask?.cancel()
        wirelessKnownPeripheralFallbackTask?.cancel()
        wirelessStateSnapshotFallbackTask?.cancel()
        wirelessControlNonceRecoveryTask?.cancel()
        secureLinkWatchdogTask?.cancel()
        firmwareUpdateWatchdogTask?.cancel()
        DistributedNotificationCenter.default().removeObserver(self)
    }

    func refreshPorts() {
        ports = SerialPortDiscovery.discover()
        if selectedPortID == nil || !ports.contains(where: { $0.id == selectedPortID }) {
            selectedPortID = ports.first?.id
        }
        autoConnectUSBIfAvailable()
    }

    private func scanBluetooth() {
        ensureBluetoothCentral()
        recordRuntimeTelemetry("scan_requested", details: "state=\(wirelessConnectionState)", once: false)
        guard let central else {
            wirelessConnectionState = "Starting"
            return
        }

        guard central.state == .poweredOn else {
            updateBluetoothAvailabilityState(central.state)
            return
        }
        guard canUseWirelessFallback else {
            stopWirelessSession(reason: wirelessStopReason)
            return
        }
        if let peripheral, peripheral.state == .connected {
            if isWirelessGattReady {
                return
            }

            wirelessConnectionState = "Discovering"
            stopWirelessScan()
            peripheral.discoverServices([serviceUUID])
            scheduleKnownPeripheralDiscoveryRetry()
            return
        }

        if peripheral?.state == .connecting {
            scheduleKnownPeripheralDiscoveryRetry()
            return
        }

        wirelessReconnectTask?.cancel()
        wirelessReconnectTask = nil
        wirelessKnownPeripheralFallbackTask?.cancel()
        wirelessKnownPeripheralFallbackTask = nil
        lastError = nil
        commandCharacteristic = nil
        stateCharacteristic = nil
        pairingCharacteristic = nil
            controlCharacteristic = nil
            isWirelessStateNotificationEnabled = false
            wirelessControlNonceRecoveryTask?.cancel()
            wirelessControlNonceRecoveryTask = nil
            stopSecureLinkWatchdog()
            invalidatePreparedFastDoorCommandPayloads(clearNonce: true)
        wirelessPairingState = "Unknown"
        hasConfirmedExpiredAutoLockDeadline = false
        if connectToKnownPeripheralIfPossible() {
            return
        }

        wirelessConnectionState = "Scanning"
        startWirelessScanIfNeeded()
    }

    private func startWirelessScanIfNeeded() {
        guard let central, central.state == .poweredOn else { return }

        let allowsDuplicates = false
        if central.isScanning, activeWirelessScanAllowsDuplicates == allowsDuplicates {
            return
        }

        central.stopScan()
        activeWirelessScanAllowsDuplicates = allowsDuplicates
        central.scanForPeripherals(
            withServices: [serviceUUID],
            options: scanOptionsForCurrentMode(allowsDuplicates: allowsDuplicates)
        )
    }

    private func stopWirelessScan() {
        central?.stopScan()
        activeWirelessScanAllowsDuplicates = nil
    }

    private func ensureBluetoothCentral() {
        guard central == nil else { return }
        central = CBCentralManager(delegate: self, queue: .main)
        recordRuntimeTelemetry("central_created")
    }

    private func updateBluetoothAvailabilityState(_ state: CBManagerState) {
        switch state {
        case .poweredOn:
            bluetoothState = "On"
        case .poweredOff:
            bluetoothState = "Off"
            wirelessConnectionState = "Bluetooth off"
        case .unauthorized:
            bluetoothState = "Unauthorized"
            wirelessConnectionState = "Bluetooth permission needed"
        case .unsupported:
            bluetoothState = "Unsupported"
            wirelessConnectionState = "Bluetooth unsupported"
        case .resetting:
            bluetoothState = "Resetting"
            wirelessConnectionState = "Bluetooth resetting"
        case .unknown:
            bluetoothState = "Unknown"
            wirelessConnectionState = "Starting"
        @unknown default:
            bluetoothState = "Unknown"
            wirelessConnectionState = "Starting"
        }
    }

    func refreshAll() {
        guard !isBusy else { return }
        Task { await run("Refreshing") { try await loadControllerState() } }
    }

    func enablePairingMode() {
        sendStatusCommand("app pair on", label: "Allow New Device", timeout: 4)
    }

    func disablePairingMode() {
        sendStatusCommand("app pair off", label: "Stop Pairing", timeout: 4)
    }

    func approvePairing() {
        let code = approvalCode.filter(\.isNumber)
        guard code.count == 4 else {
            lastError = "Enter the 4-digit code shown on the device."
            return
        }

        sendStatusCommand("app approve \(code)", label: "Approve Device", timeout: 5) { [weak self] in
            self?.approvalCode = ""
        }
    }

    func rejectPairing() {
        sendStatusCommand("app reject", label: "Reject Device", timeout: 4)
    }

    func removeSelectedDevice() {
        guard let selectedDevice else {
            lastError = DoorAdminError.noDeviceSelected.localizedDescription
            return
        }

        sendStatusCommand("app remove \(selectedDevice.slot)", label: "Remove Device", timeout: 4)
    }

    func clearAllDevices() {
        sendStatusCommand("app clear pairs", label: "Clear Devices", timeout: 4)
    }

    func renameSelectedDevice(to name: String) {
        guard let selectedDevice else {
            lastError = DoorAdminError.noDeviceSelected.localizedDescription
            return
        }

        let deviceName = DoorDeviceNameNormalizer.normalized(name, fallback: "")
        guard !deviceName.isEmpty else {
            lastError = "Enter a device name."
            return
        }

        sendStatusCommand("app rename \(selectedDevice.slot) \(deviceName)", label: "Rename Device", timeout: 4)
    }

    private func beginLocalSettingApply(_ kind: String) {
        localSettingApplyKind = kind
    }

    private func clearLocalSettingApply(_ kind: String) {
        if localSettingApplyKind == kind {
            localSettingApplyKind = nil
        }
    }

    func updateAutoLockSeconds(_ seconds: Int) {
        let clampedSeconds = min(max(seconds, Self.minimumAutoLockSeconds), Self.maximumAutoLockSeconds)
        guard clampedSeconds != status.autoLockSeconds || pendingAutoLockSeconds != nil else { return }

        beginLocalSettingApply("timeout")
        pendingAutoLockSeconds = clampedSeconds
        autoLockStatus = canSendDoorCommand ? "Setting..." : "Waiting for controller"

        var nextStatus = status
        nextStatus.autoLockSeconds = clampedSeconds
        if nextStatus.isUnlocked {
            nextStatus.autoLockRemainingSeconds = clampedSeconds
            nextStatus.autoLockDeadline = Date().addingTimeInterval(TimeInterval(clampedSeconds))
            hasConfirmedExpiredAutoLockDeadline = false
        }
        status = nextStatus

        autoLockApplyTask?.cancel()
        autoLockApplyTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            await MainActor.run {
                self?.autoLockApplyTask = nil
            }
            await self?.applyPendingAutoLockSeconds()
        }
    }

    func updateLockServoAngle(_ angle: Int) {
        updateServoAngles(ServoAngles(lockAngle: angle, unlockAngle: status.unlockAngle))
    }

    func updateUnlockServoAngle(_ angle: Int) {
        updateServoAngles(ServoAngles(lockAngle: status.lockAngle, unlockAngle: angle))
    }

    func resetServoAnglesToDefaults() {
        updateServoAngles(ServoAngles(
            lockAngle: ControllerStatus.defaultLockAngle,
            unlockAngle: ControllerStatus.defaultUnlockAngle
        ))
    }

    private func updateServoAngles(_ requestedAngles: ServoAngles) {
        let clampedAngles = clampedServoAngles(requestedAngles)
        guard servoAnglesAreValid(clampedAngles) else {
            lastError = "Keep servo angles \(status.servoMinAngleGap) degrees apart and inside \(servoAngleRange.lowerBound)-\(servoAngleRange.upperBound) degrees."
            return
        }
        guard clampedAngles != status.servoAngles || pendingServoAngles != nil else { return }

        beginLocalSettingApply("servo_angles")
        pendingServoAngles = clampedAngles
        servoAnglesStatus = canSendDoorCommand ? "Setting..." : "Waiting for controller"

        var nextStatus = status
        nextStatus.lockAngle = clampedAngles.lockAngle
        nextStatus.unlockAngle = clampedAngles.unlockAngle
        status = nextStatus

        servoAnglesApplyTask?.cancel()
        servoAnglesApplyTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            await MainActor.run {
                self?.servoAnglesApplyTask = nil
            }
            await self?.applyPendingServoAngles()
        }
    }

    func lock() {
        sendDoorCommand(.lock)
    }

    func unlock() {
        sendDoorCommand(.unlock)
    }

    func toggleLock() {
        status.isUnlocked ? lock() : unlock()
    }

    func startFirmwareUpdate(from packageURL: URL) {
        firmwareLog.info("Firmware update requested from \(packageURL.path, privacy: .public)")
        guard !isFirmwareUpdateRunning else {
            firmwareUpdateStatus = "Firmware update already running"
            lastError = "A firmware update is already in progress."
            firmwareLog.error("Ignored firmware update request because one is already running")
            return
        }
        guard packageURL.pathExtension.localizedCaseInsensitiveCompare("zip") == .orderedSame else {
            lastError = "Choose a firmware .zip package."
            return
        }

        do {
            let localPackageURL = try copyFirmwarePackageToTemporaryLocation(from: packageURL)
            startFirmwareUpdate(packageURL: localPackageURL)
        } catch {
            lastError = error.localizedDescription
            firmwareUpdateStatus = "Could not prepare firmware package"
            firmwareUpdateProgress = nil
            isFirmwareUpdateRunning = false
        }
    }

    func recoverFirmwareUpdate(from packageURL: URL) {
        firmwareLog.info("Firmware recovery upload requested from \(packageURL.path, privacy: .public)")
        guard !isFirmwareUpdateRunning else {
            firmwareUpdateStatus = "Firmware update already running"
            lastError = "A firmware update is already in progress."
            return
        }
        guard packageURL.pathExtension.localizedCaseInsensitiveCompare("zip") == .orderedSame else {
            lastError = "Choose a firmware .zip package."
            return
        }

        do {
            let localPackageURL = try copyFirmwarePackageToTemporaryLocation(from: packageURL)
            pendingFirmwareUpdatePackageURL = nil
            firmwareUpdateStatus = "Recovering firmware update"
            firmwareUpdateProgress = nil
            isFirmwareUpdateRunning = true
            lastError = nil
            switchUSBToWirelessFirmwareUpdateIfNeeded()
            beginFirmwareDfuUpload(after: localPackageURL)
        } catch {
            lastError = error.localizedDescription
            firmwareUpdateStatus = "Could not prepare firmware package"
            firmwareUpdateProgress = nil
            isFirmwareUpdateRunning = false
        }
    }

    private func copyFirmwarePackageToTemporaryLocation(from url: URL) throws -> URL {
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
        pendingFirmwareUpdatePackageURL = packageURL
        firmwareUpdateEntryCommandSent = false
        firmwareUpdateStatus = "Preparing firmware update"
        firmwareUpdateProgress = nil
        isFirmwareUpdateRunning = true
        lastError = nil
        firmwareLog.info("Start requested package=\(packageURL.path, privacy: .public) usb=\(self.isConnected, privacy: .public) wirelessReady=\(self.isWirelessReady, privacy: .public) canUseWireless=\(self.canUseWirelessFallback, privacy: .public)")
        scheduleFirmwareUpdateCommandWatchdog()

        switchUSBToWirelessFirmwareUpdateIfNeeded()

        if isWirelessReady {
            firmwareLog.info("Wireless already ready; sending OTA request")
            _ = sendPendingFirmwareUpdateCommandIfReady()
        } else if canUseWirelessFallback {
            firmwareUpdateStatus = "Connecting wirelessly"
            firmwareLog.info("Queueing OTA request while wireless connects")
            queueWirelessCommand("ENTER_OTA_DFU", intent: .firmwareUpdate(packageURL))
            scanBluetooth()
        } else {
            pendingFirmwareUpdatePackageURL = nil
            firmwareUpdateStatus = "Pair this Mac over USB-C first"
            firmwareUpdateProgress = nil
            isFirmwareUpdateRunning = false
            firmwareUpdateWatchdogTask?.cancel()
            firmwareUpdateWatchdogTask = nil
            lastError = "This Mac is not trusted for wireless firmware updates yet. Connect over USB-C once, then try again."
        }
    }

    private func scheduleFirmwareUpdateCommandWatchdog() {
        firmwareUpdateWatchdogTask?.cancel()
        firmwareUpdateWatchdogTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 25_000_000_000)
            await MainActor.run {
                guard let self,
                      self.isFirmwareUpdateRunning,
                      self.pendingFirmwareUpdatePackageURL != nil else {
                    return
                }

                self.firmwareLog.error("Firmware update timed out before controller entered DFU mode")
                self.pendingFirmwareUpdatePackageURL = nil
                self.firmwareUpdateEntryCommandSent = false
                if case .firmwareUpdate = self.pendingWirelessCommandIntent {
                    self.pendingWirelessCommandText = nil
                    self.pendingWirelessPredictedCommand = nil
                    self.pendingWirelessCommandIntent = nil
                }
                self.firmwareUpdateStatus = "Firmware update timed out"
                self.firmwareUpdateProgress = nil
                self.isFirmwareUpdateRunning = false
                self.lastError = "The controller did not enter firmware update mode. Try again near the controller or use USB-C recovery."
                self.firmwareUpdateWatchdogTask = nil
                self.scanBluetooth()
            }
        }
    }

    private func switchUSBToWirelessFirmwareUpdateIfNeeded() {
        guard isConnected || isUSBConnectInFlight else { return }

        firmwareLog.info("Closing USB session so firmware update can use BLE")
        cancelUSBStartupSync()
        connection?.close()
        connection = nil
        isConnected = false
        isUSBConnectInFlight = false
        lastUSBStatusSyncAt = nil
        didTrustMacDuringUSBSession = false
        status = statusRemovingLocalUSBConnection(status)
        message = "Switching to wireless update"
        ensureBluetoothCentral()
    }

    private func beginUSBFirmwareUpdateMode(packageURL: URL) {
        guard !isBusy else {
            firmwareUpdateStatus = "Controller is busy"
            firmwareUpdateProgress = nil
            isFirmwareUpdateRunning = false
            return
        }
        cancelUSBStartupSync()
        Task {
            await run("Firmware update") {
                firmwareUpdateStatus = "Requesting firmware update mode over USB-C"
                let lines = try await transact("app ota", until: ["APP_OK firmware_update=ota_dfu"], timeout: 4)
                appendLog(lines)
                pendingFirmwareUpdatePackageURL = nil
                beginFirmwareDfuUpload(after: packageURL)
            }
        }
    }

    @discardableResult
    private func sendPendingFirmwareUpdateCommandIfReady() -> Bool {
        guard let packageURL = pendingFirmwareUpdatePackageURL else { return false }
        guard !firmwareUpdateEntryCommandSent else { return false }

        guard isWirelessReady else {
            firmwareUpdateStatus = "Connecting wirelessly"
            firmwareLog.info("OTA request waiting for wireless readiness")
            scanBluetooth()
            return false
        }

        guard fastCommandNonce != nil else {
            firmwareUpdateStatus = "Preparing secure command"
            firmwareLog.info("OTA request waiting for secure nonce")
            requestWirelessControlNonce()
            return false
        }

        firmwareUpdateStatus = "Requesting firmware update mode"
        firmwareLog.info("Sending secure OTA DFU entry command")
        if sendWirelessCommandText("ENTER_OTA_DFU", intent: .firmwareUpdate(packageURL)) {
            firmwareUpdateEntryCommandSent = true
            stopSecureLinkWatchdog()
            pendingWirelessCommandText = nil
            pendingWirelessPredictedCommand = nil
            pendingWirelessCommandIntent = nil
            firmwareLog.info("Secure OTA DFU entry command queued/written")
            return true
        }

        firmwareUpdateStatus = "Could not request firmware update mode"
        firmwareUpdateProgress = nil
        isFirmwareUpdateRunning = false
        pendingFirmwareUpdatePackageURL = nil
        firmwareUpdateEntryCommandSent = false
        firmwareLog.error("Secure OTA DFU entry command failed before write")
        return false
    }

    private func beginFirmwareDfuUpload(after packageURL: URL) {
        firmwareUpdateStatus = "Waiting for update bootloader"
        firmwareUpdateProgress = nil
        firmwareUpdateWatchdogTask?.cancel()
        firmwareUpdateWatchdogTask = nil
        firmwareLog.info("Starting Nordic DFU manager package=\(packageURL.path, privacy: .public)")
        firmwareDfuManager.start(packageURL: packageURL)
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

    private func applyRemoteSettingApplying(kind: String, value: String?) {
        remoteSettingApplyTask?.cancel()
        remoteSettingApplyValue = value
        remoteSettingApplyKind = kind
        remoteSettingApplyTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
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

    @objc private func handleLocalCommandNotification(_ notification: Notification) {
        guard let command = notification.userInfo?[DoorLocalCommandBridge.commandKey] as? String else { return }

        switch command {
        case "lock":
            lock()
        case "unlock":
            unlock()
        case "toggle":
            toggleLock()
        case "timeout":
            guard let rawSeconds = notification.userInfo?[DoorLocalCommandBridge.argumentKey] as? String,
                  let seconds = Int(rawSeconds) else { return }
            updateAutoLockSeconds(seconds)
        case "angles":
            guard let rawAngles = notification.userInfo?[DoorLocalCommandBridge.argumentKey] as? String else { return }
            let parts = rawAngles.split(separator: " ").compactMap { Int($0) }
            guard parts.count >= 2 else { return }
            updateServoAngles(ServoAngles(lockAngle: parts[0], unlockAngle: parts[1]))
        case "firmware":
            guard let rawPath = notification.userInfo?[DoorLocalCommandBridge.argumentKey] as? String else { return }
            startFirmwareUpdate(from: URL(fileURLWithPath: rawPath))
        case "firmware-recover":
            guard let rawPath = notification.userInfo?[DoorLocalCommandBridge.argumentKey] as? String else { return }
            recoverFirmwareUpdate(from: URL(fileURLWithPath: rawPath))
        default:
            break
        }
    }

    private func sendDoorCommand(_ command: Command) {
        if isConnected {
            applyPredictedDoorCommand(command)
            switch command {
            case .lock:
                sendStatusCommand(Self.appLockCommandText(), label: "Lock", timeout: 6, refreshPairsAfterSuccess: false)
            case .unlock:
                sendStatusCommand(Self.appUnlockCommandText(), label: "Unlock", timeout: 6, refreshPairsAfterSuccess: false)
            }
        } else if isWirelessReady {
            sendWirelessCommandText(command.commandText, predictedDoorCommand: command, intent: .doorCommand)
        } else {
            queueWirelessCommand(command.commandText, predictedDoorCommand: command, intent: .doorCommand)
        }
    }

    private func applyPredictedDoorCommand(_ command: Command) {
        let predictedState = command == .unlock ? "unlocking" : "locking"
        var nextStatus = status
        nextStatus.bleState = predictedState
        nextStatus.isUnlocked = command == .unlock
        nextStatus.autoLockRemainingSeconds = nil
        nextStatus.autoLockDeadline = nil
        status = nextStatus
        saveCachedStatus(nextStatus)
        hasConfirmedExpiredAutoLockDeadline = false
        message = command == .unlock ? "Unlocking door" : "Locking door"
    }

    private func queueWirelessCommand(
        _ commandText: String,
        predictedDoorCommand: Command? = nil,
        intent: WirelessCommandWriteIntent = .generic
    ) {
        pendingWirelessCommandText = commandText
        pendingWirelessPredictedCommand = predictedDoorCommand
        pendingWirelessCommandIntent = intent
        if !canQueueWirelessCommandForKnownController {
            wirelessConnectionState = "Connecting on demand"
        }
        if let predictedDoorCommand {
            message = predictedDoorCommand == .unlock ? "Preparing unlock" : "Preparing lock"
        }

        guard hasTrustedMacController else {
            lastError = "Pair this Mac over USB-C before using wireless commands."
            wirelessPairingState = "USB-C trust needed"
            pendingWirelessCommandText = nil
            pendingWirelessPredictedCommand = nil
            pendingWirelessCommandIntent = nil
            return
        }

        if isWirelessReady {
            sendQueuedWirelessCommand()
        } else {
            scanBluetooth()
        }
    }

    private func sendQueuedWirelessCommand() {
        guard let commandText = pendingWirelessCommandText else { return }
        let predictedCommand = pendingWirelessPredictedCommand
        let intent = pendingWirelessCommandIntent ?? .generic
        queuedWirelessCommandDuringCurrentSend = false
        if sendWirelessCommandText(commandText, predictedDoorCommand: predictedCommand, intent: intent) {
            if !queuedWirelessCommandDuringCurrentSend {
                pendingWirelessCommandText = nil
                pendingWirelessPredictedCommand = nil
                pendingWirelessCommandIntent = nil
            }
        }
        queuedWirelessCommandDuringCurrentSend = false
    }

    private func telemetryCommandLabel(
        commandText: String,
        predictedDoorCommand: Command?,
        intent: WirelessCommandWriteIntent
    ) -> String {
        switch intent {
        case .doorCommand:
            return predictedDoorCommand?.rawValue ?? "door command"
        case .autoLockTimeout(let seconds):
            return "auto-lock \(seconds)s"
        case .lockName:
            return "lock name"
        case .servoAngles(let angles):
            return "angles \(angles.lockAngle)/\(angles.unlockAngle)"
        case .firmwareUpdate:
            return "firmware update"
        case .generic:
            return commandText
        }
    }

    @discardableResult
    private func sendWirelessCommandText(
        _ commandText: String,
        predictedDoorCommand: Command? = nil,
        intent: WirelessCommandWriteIntent = .generic
    ) -> Bool {
        queuedWirelessCommandDuringCurrentSend = false
        guard let peripheral, let commandCharacteristic else {
            if hasTrustedMacController, canUseWirelessFallback {
                queueWirelessCommandForConnectionReadiness(
                    commandText,
                    predictedDoorCommand: predictedDoorCommand,
                    intent: intent
                )
                return true
            }
            lastError = "Not connected wirelessly."
            return false
        }
        guard hasTrustedMacController else {
            lastError = "Pair this Mac over USB-C before using wireless commands."
            wirelessPairingState = "USB-C trust needed"
            pendingWirelessCommandText = nil
            pendingWirelessPredictedCommand = nil
            pendingWirelessCommandIntent = nil
            scheduleWirelessIdleDisconnect(after: 0.5)
            return false
        }
        guard isWirelessGattReady else {
            queueWirelessCommandForConnectionReadiness(
                commandText,
                predictedDoorCommand: predictedDoorCommand,
                intent: intent
            )
            return true
        }

        if case .doorCommand = intent {
            guard let predictedDoorCommand else {
                lastError = "Door command is missing."
                return false
            }
            if let preparedFastPayload = preparedFastDoorCommandPayloads[predictedDoorCommand],
               let writeType = preferredFastDoorCommandWriteType(
                    for: preparedFastPayload.data,
                    peripheral: peripheral,
                    characteristic: commandCharacteristic
               ) {
                invalidatePreparedFastDoorCommandPayloads(clearNonce: true)
                lastError = nil
                applyPredictedDoorCommand(predictedDoorCommand)
                fastDoorCommandInFlight = predictedDoorCommand
                peripheral.writeValue(preparedFastPayload.data, for: commandCharacteristic, type: writeType)
                recordRuntimeTelemetry("wireless_command_sent", details: telemetryCommandLabel(commandText: commandText, predictedDoorCommand: predictedDoorCommand, intent: intent), once: false)
                scheduleWirelessIdleDisconnect()
                return true
            }

            if let nonce = fastCommandNonce {
                do {
                    let fastPayload = try DoorCommandAuthenticator.fastCommandPayload(
                        for: predictedDoorCommand.authenticatorFastCommand,
                        nonce: nonce
                    )
                    guard let writeType = preferredFastDoorCommandWriteType(
                        for: fastPayload.data,
                        peripheral: peripheral,
                        characteristic: commandCharacteristic
                    ) else {
                        lastError = "Secure command is too large for this Bluetooth connection."
                        return false
                    }

                    invalidatePreparedFastDoorCommandPayloads(clearNonce: true)
                    lastError = nil
                    applyPredictedDoorCommand(predictedDoorCommand)
                    fastDoorCommandInFlight = predictedDoorCommand
                    peripheral.writeValue(fastPayload.data, for: commandCharacteristic, type: writeType)
                    recordRuntimeTelemetry("wireless_command_sent", details: telemetryCommandLabel(commandText: commandText, predictedDoorCommand: predictedDoorCommand, intent: intent), once: false)
                    scheduleWirelessIdleDisconnect()
                    return true
                } catch {
                    lastError = error.localizedDescription
                    return false
                }
            }

            queueWirelessCommandForSecureNonce(
                commandText,
                predictedDoorCommand: predictedDoorCommand,
                intent: intent
            )
            return true
        }

        guard let nonce = fastCommandNonce else {
            queueWirelessCommandForSecureNonce(
                commandText,
                predictedDoorCommand: predictedDoorCommand,
                intent: intent
            )
            return true
        }

        do {
            let v3Payload = try DoorCommandAuthenticator.secureCommandPayload(for: commandText, nonce: nonce)
            let payload = v3Payload.data
            guard let writeType = preferredWirelessWriteType(for: payload, intent: intent, peripheral: peripheral, characteristic: commandCharacteristic) else {
                lastError = "Secure command is too large for this Bluetooth connection."
                return false
            }

            lastError = nil
            invalidatePreparedFastDoorCommandPayloads(clearNonce: true)
            if let predictedDoorCommand {
                applyPredictedDoorCommand(predictedDoorCommand)
            }
            if writeType == .withResponse {
                pendingWirelessWriteIntents.append(intent)
            }
            peripheral.writeValue(payload, for: commandCharacteristic, type: writeType)
            recordRuntimeTelemetry("wireless_command_sent", details: telemetryCommandLabel(commandText: commandText, predictedDoorCommand: predictedDoorCommand, intent: intent), once: false)
            if writeType == .withoutResponse {
                if case .firmwareUpdate = intent {
                    firmwareLog.info("OTA DFU entry command written without response; waiting for controller update mode")
                    firmwareUpdateStatus = "Waiting for controller update mode"
                } else {
                    scheduleWirelessIdleDisconnect()
                }
            }
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    private func queueWirelessCommandForSecureNonce(
        _ commandText: String,
        predictedDoorCommand: Command?,
        intent: WirelessCommandWriteIntent
    ) {
        pendingWirelessCommandText = commandText
        pendingWirelessPredictedCommand = predictedDoorCommand
        pendingWirelessCommandIntent = intent
        queuedWirelessCommandDuringCurrentSend = true
        lastError = nil

        if let nonce = fastCommandNonce {
            if predictedDoorCommand != nil {
                if preparedFastDoorCommandTask == nil {
                    prepareFastDoorCommandPayloads(for: nonce)
                }
            } else {
                _ = sendQueuedWirelessNonDoorCommandIfReady()
            }
            return
        }

        requestWirelessControlNonce()
    }

    private func queueWirelessCommandForConnectionReadiness(
        _ commandText: String,
        predictedDoorCommand: Command?,
        intent: WirelessCommandWriteIntent
    ) {
        pendingWirelessCommandText = commandText
        pendingWirelessPredictedCommand = predictedDoorCommand
        pendingWirelessCommandIntent = intent
        queuedWirelessCommandDuringCurrentSend = true
        lastError = nil

        guard canUseWirelessFallback else { return }
        if let peripheral, peripheral.state == .connected {
            wirelessConnectionState = "Discovering"
            peripheral.discoverServices([serviceUUID])
            scheduleKnownPeripheralDiscoveryRetry()
        } else {
            scanBluetooth()
        }
    }

    private func preferredFastDoorCommandWriteType(
        for payload: Data,
        peripheral: CBPeripheral,
        characteristic: CBCharacteristic
    ) -> CBCharacteristicWriteType? {
        guard characteristic.properties.contains(.writeWithoutResponse),
              payload.count <= peripheral.maximumWriteValueLength(for: .withoutResponse) else {
            return nil
        }

        return .withoutResponse
    }

    private func preferredWirelessWriteType(
        for payload: Data,
        intent: WirelessCommandWriteIntent,
        peripheral: CBPeripheral,
        characteristic: CBCharacteristic
    ) -> CBCharacteristicWriteType? {
        let canWriteWithoutResponse = characteristic.properties.contains(.writeWithoutResponse)
        let canWriteWithResponse = characteristic.properties.contains(.write)
        let isDoorCommand: Bool
        if case .doorCommand = intent {
            isDoorCommand = true
        } else {
            isDoorCommand = false
        }
        let isFirmwareUpdate: Bool
        if case .firmwareUpdate = intent {
            isFirmwareUpdate = true
        } else {
            isFirmwareUpdate = false
        }

        if isFirmwareUpdate,
           canWriteWithoutResponse,
           payload.count <= peripheral.maximumWriteValueLength(for: .withoutResponse) {
            return .withoutResponse
        }

        if isDoorCommand,
           canWriteWithResponse,
           payload.count <= peripheral.maximumWriteValueLength(for: .withResponse) {
            return .withResponse
        }

        if canWriteWithResponse,
           payload.count <= peripheral.maximumWriteValueLength(for: .withResponse) {
            return .withResponse
        }

        if canWriteWithoutResponse,
           payload.count <= peripheral.maximumWriteValueLength(for: .withoutResponse) {
            return .withoutResponse
        }

        return nil
    }

    private func connectToSelectedPort(allowScheduledStart: Bool = false) async {
        guard allowScheduledStart || !isUSBConnectInFlight else { return }

        isUSBConnectInFlight = true
        lastError = nil
        message = "Opening USB-C"

        do {
            guard let selectedPort else { throw DoorAdminError.noPortSelected }

            cancelUSBStartupSync()
            connection?.close()
            connection = try SerialPortConnection(path: selectedPort.path)
            isConnected = true
            isUSBConnectInFlight = false
            status = statusIncludingLocalUSBConnection(status)
            lastUSBStatusSyncAt = .now
            lastPairedDevicesSyncAt = .now
            lastUSBDiscoveryAt = nil
            didTrustMacDuringUSBSession = false
            message = "USB-C ready"
            recordRuntimeTelemetry("usb_ready", details: selectedPort.displayName)
            stopWirelessSession(reason: "USB-C active")
            usbStartupSyncTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: Self.usbStartupSyncGraceNanoseconds)
                guard !Task.isCancelled else { return }
                await self?.finishUSBStartupSync()
            }
        } catch {
            isUSBConnectInFlight = false
            connection?.close()
            connection = nil
            isConnected = false
            lastError = error.localizedDescription
            message = "USB-C unavailable"
            ensureBluetoothCentral()
            if central?.state == .poweredOn, canUseWirelessFallback {
                scanBluetooth()
            }
        }
    }

    private func finishUSBStartupSync() async {
        guard isConnected else { return }
        defer { usbStartupSyncTask = nil }
        recordRuntimeTelemetry("usb_startup_sync_start")

        do {
            do {
                try await loadControllerState(statusTimeout: 0.8, pairTimeout: 0.8)
            } catch {
                guard !Task.isCancelled else { return }
                try await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
                try await loadControllerState(statusTimeout: 2, pairTimeout: 2)
            }
            guard !Task.isCancelled else { return }
            lastUSBStatusSyncAt = .now
            try await trustThisMacOverUSBIfNeeded()
            guard !Task.isCancelled else { return }
            await applyPendingAutoLockSeconds()
            await applyPendingServoAngles()
            await applyPendingLockName()
            recordRuntimeTelemetry("usb_startup_sync_done")
        } catch {
            guard isConnected else { return }
            if !selectedUSBPortStillPresent() {
                markUSBDisconnected(reason: "USB-C disconnected")
                return
            }

            lastError = error.localizedDescription
            if message == "Opening USB-C" || message == "Connecting to controller" {
                message = "USB-C connected"
            }
        }
    }

    private func cancelUSBStartupSync() {
        usbStartupSyncTask?.cancel()
        usbStartupSyncTask = nil
    }

    private func autoConnectUSBIfAvailable() {
        guard selectedPort != nil,
              !isConnected,
              !isBusy,
              !isFirmwareUpdateRunning,
              !isUSBConnectInFlight else { return }

        isUSBConnectInFlight = true
        message = "Opening USB-C"
        recordRuntimeTelemetry("usb_auto_connect_start")
        stopWirelessSession(reason: "USB-C active")
        Task { await connectToSelectedPort(allowScheduledStart: true) }
    }

    private func markUSBDisconnected(reason: String) {
        cancelUSBStartupSync()
        connection?.close()
        connection = nil
        isConnected = false
        isUSBConnectInFlight = false
        lastUSBStatusSyncAt = nil
        didTrustMacDuringUSBSession = false
        status = statusRemovingLocalUSBConnection(status)
        message = reason

        ensureBluetoothCentral()
        if central?.state == .poweredOn, canUseWirelessFallback {
            scanBluetooth()
        } else {
            stopWirelessSession(reason: "Idle")
        }
    }

    private func selectedUSBPortStillPresent() -> Bool {
        guard let selectedPortID else { return false }
        return SerialPortDiscovery.discover().contains { $0.id == selectedPortID }
    }

    private func refreshUSBPortsIfNeeded() {
        guard !isConnected, !isBusy, !isUSBConnectInFlight else { return }

        let now = Date()
        guard lastUSBDiscoveryAt.map({ now.timeIntervalSince($0) >= 2 }) ?? true else { return }

        lastUSBDiscoveryAt = now
        refreshPorts()
    }

    private func trustThisMacOverUSBIfNeeded() async throws {
        guard isConnected, !didTrustMacDuringUSBSession else { return }

        let deviceName = localMacDeviceName
        if hasTrustedMacController,
           pairedDevices.contains(where: { Self.deviceName($0.displayName, matches: deviceName) }) {
            setTrustedMacController(true)
            didTrustMacDuringUSBSession = true
            message = "USB-C ready"
            return
        }

        let payloadHex = try DoorCommandAuthenticator.pairingPayloadHex(deviceName: deviceName)
        let lines = try await transact("app pair usb \(payloadHex)", until: ["APP_STATUS_END"], timeout: 5)
        appendLog(lines)
        applyControllerStatus(DoorSerialParser.parseStatus(from: lines))
        try await loadPairedDevices()

        if let errorLine = lines.first(where: { $0.hasPrefix("APP_ERROR") }) {
            lastError = "Could not trust this Mac automatically: \(errorLine)"
        } else {
            setTrustedMacController(true)
            didTrustMacDuringUSBSession = true
            message = "USB-C ready"
        }
    }

    private static func deviceName(_ candidate: String, matches expected: String) -> Bool {
        let normalizedCandidate = DoorDeviceNameNormalizer.normalized(candidate, fallback: "")
        let normalizedExpected = DoorDeviceNameNormalizer.normalized(expected, fallback: "")
        guard !normalizedCandidate.isEmpty, !normalizedExpected.isEmpty else { return false }
        return normalizedCandidate == normalizedExpected
    }

    private func setTrustedMacController(_ isTrusted: Bool) {
        hasTrustedMacController = isTrusted
        UserDefaults.standard.set(isTrusted, forKey: Self.trustedMacControllerKey)
        if isTrusted {
            let cachedCount = UserDefaults.standard.object(forKey: Self.cachedPairedCountKey) == nil
                ? 0
                : UserDefaults.standard.integer(forKey: Self.cachedPairedCountKey)
            UserDefaults.standard.set(max(cachedCount, 1), forKey: Self.cachedPairedCountKey)
            var nextStatus = status
            nextStatus.pairedCount = max(nextStatus.pairedCount, 1)
            nextStatus.maxPairs = max(nextStatus.maxPairs, 4)
            status = nextStatus
            saveCachedStatus(nextStatus)
        }
    }

    private func sendStatusCommand(
        _ command: String,
        label: String,
        timeout: TimeInterval,
        refreshPairsAfterSuccess: Bool = true,
        afterSuccess: (() -> Void)? = nil
    ) {
        guard !isBusy else { return }
        cancelUSBStartupSync()
        Task {
            await run(label) {
                recordRuntimeTelemetry("usb_command_start", details: label, once: false)
                let lines = try await transact(command, until: ["APP_STATUS_END"], timeout: timeout)
                appendLog(lines)
                applyControllerStatus(DoorSerialParser.parseStatus(from: lines))
                message = successMessage(for: label, status: status)
                if refreshPairsAfterSuccess {
                    try await loadPairedDevices()
                }
                afterSuccess?()
                recordRuntimeTelemetry("usb_command_done", details: label, once: false)
            }
        }
    }

    private func run(_ label: String, operation: () async throws -> Void) async {
        isBusy = true
        lastError = nil
        message = label
        defer { isBusy = false }

        do {
            try await operation()
        } catch {
            if label == "Auto-lock" {
                inFlightAutoLockSeconds = nil
                if pendingAutoLockSeconds == nil {
                    clearLocalSettingApply("timeout")
                    autoLockStatus = "Not set"
                }
            }
            if label == "Servo angles" {
                inFlightServoAngles = nil
                if pendingServoAngles == nil {
                    clearLocalSettingApply("servo_angles")
                    servoAnglesStatus = "Not set"
                }
            }
            if label == "Firmware update" {
                pendingFirmwareUpdatePackageURL = nil
                firmwareUpdateEntryCommandSent = false
                firmwareUpdateStatus = "Firmware update failed"
                firmwareUpdateProgress = nil
                isFirmwareUpdateRunning = false
            }
            lastError = error.localizedDescription
            message = "Something went wrong"
            appendLog(["ERROR \(error.localizedDescription)"])
        }
    }

    private func loadControllerState(statusTimeout: TimeInterval = 4, pairTimeout: TimeInterval = 4) async throws {
        let statusLines = try await transact("app status", until: ["APP_STATUS_END"], timeout: statusTimeout)
        appendLog(statusLines)
        applyControllerStatus(DoorSerialParser.parseStatus(from: statusLines))
        message = statusMessage(for: status)
        try await loadPairedDevices(timeout: pairTimeout)
    }

    private func loadPairedDevices(shouldLog: Bool = true, timeout: TimeInterval = 4) async throws {
        let pairLines = try await transact("app pairs", until: ["APP_PAIRS_END"], timeout: timeout)
        if shouldLog {
            appendLog(pairLines)
        }
        pairedDevices = DoorSerialParser.parsePairs(from: pairLines)
        lastPairedDevicesSyncAt = .now
        var nextStatus = status
        nextStatus.pairedCount = pairedDevices.count
        nextStatus.maxPairs = max(nextStatus.maxPairs, nextStatus.pairedCount, 4)
        status = nextStatus
        saveCachedStatus(nextStatus)

        if let selectedDeviceID, pairedDevices.contains(where: { $0.id == selectedDeviceID }) {
            return
        }

        selectedDeviceID = pairedDevices.first?.id
    }

    private func applyPendingAutoLockSeconds() async {
        guard let seconds = pendingAutoLockSeconds else {
            if inFlightAutoLockSeconds == nil {
                clearLocalSettingApply("timeout")
            }
            return
        }

        if isBusy {
            schedulePendingAutoLockRetry()
            return
        }

        if isConnected {
            inFlightAutoLockSeconds = seconds
            pendingAutoLockSeconds = nil
            autoLockStatus = "Setting..."
            sendStatusCommand("app timeout \(seconds)", label: "Auto-lock", timeout: 4, refreshPairsAfterSuccess: false)
            return
        }

        if isWirelessReady {
            inFlightAutoLockSeconds = seconds
            pendingAutoLockSeconds = nil
            autoLockStatus = "Setting..."
            if !sendWirelessCommandText("SET_TIMEOUT:\(seconds)", intent: .autoLockTimeout(seconds)) {
                inFlightAutoLockSeconds = nil
                pendingAutoLockSeconds = seconds
                autoLockStatus = "Not set"
            }
            return
        }

        inFlightAutoLockSeconds = seconds
        pendingAutoLockSeconds = nil
        autoLockStatus = "Setting..."
        queueWirelessCommand("SET_TIMEOUT:\(seconds)", intent: .autoLockTimeout(seconds))
    }

    private func applyPendingServoAngles() async {
        guard let angles = pendingServoAngles else {
            if inFlightServoAngles == nil {
                clearLocalSettingApply("servo_angles")
            }
            return
        }

        if isBusy && isConnected {
            schedulePendingServoAnglesRetry()
            return
        }

        let command = "SET_ANGLES:\(angles.lockAngle),\(angles.unlockAngle)"
        if isConnected {
            inFlightServoAngles = angles
            pendingServoAngles = nil
            servoAnglesStatus = "Setting..."
            sendStatusCommand("app angles \(angles.lockAngle) \(angles.unlockAngle)", label: "Servo angles", timeout: 4, refreshPairsAfterSuccess: false)
            return
        }

        if isWirelessReady {
            inFlightServoAngles = angles
            pendingServoAngles = nil
            servoAnglesStatus = "Setting..."
            if !sendWirelessCommandText(command, intent: .servoAngles(angles)) {
                inFlightServoAngles = nil
                pendingServoAngles = angles
                servoAnglesStatus = "Not set"
            }
            return
        }

        inFlightServoAngles = angles
        pendingServoAngles = nil
        servoAnglesStatus = "Setting..."
        queueWirelessCommand(command, intent: .servoAngles(angles))
    }

    private func schedulePendingAutoLockRetry() {
        autoLockApplyTask?.cancel()
        autoLockApplyTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 750_000_000)
            await MainActor.run {
                self?.autoLockApplyTask = nil
            }
            await self?.applyPendingAutoLockSeconds()
        }
    }

    private func schedulePendingServoAnglesRetry() {
        servoAnglesApplyTask?.cancel()
        servoAnglesApplyTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 750_000_000)
            await MainActor.run {
                self?.servoAnglesApplyTask = nil
            }
            await self?.applyPendingServoAngles()
        }
    }

    private func applyControllerStatus(_ nextStatus: ControllerStatus) {
        let previousBleState = status.bleState
        var nextStatus = nextStatus
        if let applyingKind = nextStatus.settingApplyingKind {
            applyRemoteSettingApplying(kind: applyingKind, value: nextStatus.settingApplyingValue)
            nextStatus.settingApplyingKind = nil
            nextStatus.settingApplyingValue = nil
        }
        reconcileAutoLockSeconds(in: &nextStatus)
        reconcileServoAngles(in: &nextStatus)
        applyControllerLockName(nextStatus.lockName)
        nextStatus = statusIncludingLocalUSBConnection(nextStatus)

        if !nextStatus.isUnlocked || autoLockDeadlineChanged(from: status.autoLockDeadline, to: nextStatus.autoLockDeadline) {
            hasConfirmedExpiredAutoLockDeadline = false
        }
        status = nextStatus
        saveCachedStatus(nextStatus)
        if previousBleState != nextStatus.bleState {
            recordRuntimeTelemetry("status_state", details: "\(previousBleState) -> \(nextStatus.bleState)", once: false)
        }
    }

    private func statusIncludingLocalUSBConnection(_ status: ControllerStatus) -> ControllerStatus {
        guard isConnected || isUSBConnectInFlight else {
            return statusRemovingLocalUSBConnection(status)
        }

        return status.includingLocalConnection(localUSBDevice)
    }

    private func statusRemovingLocalUSBConnection(_ status: ControllerStatus) -> ControllerStatus {
        status.removingConnection(handle: Self.localUSBDeviceHandle)
    }

    private func reconcileAutoLockSeconds(in nextStatus: inout ControllerStatus) {
        clearRemoteSettingApplying()
        let controllerSeconds = min(max(nextStatus.autoLockSeconds, Self.minimumAutoLockSeconds), Self.maximumAutoLockSeconds)

        if pendingAutoLockSeconds == controllerSeconds {
            pendingAutoLockSeconds = nil
        }

        if inFlightAutoLockSeconds == controllerSeconds {
            inFlightAutoLockSeconds = nil
        }

        let hasNewerLocalIntent = status.autoLockSeconds != controllerSeconds
            && (autoLockApplyTask != nil || pendingAutoLockSeconds != nil || inFlightAutoLockSeconds != nil)

        guard !hasNewerLocalIntent else {
            nextStatus.autoLockSeconds = status.autoLockSeconds
            if status.isUnlocked {
                nextStatus.autoLockRemainingSeconds = status.autoLockRemainingSeconds
                nextStatus.autoLockDeadline = status.autoLockDeadline
            }
            autoLockStatus = canSendDoorCommand ? "Setting..." : "Waiting for controller"
            return
        }

        nextStatus.autoLockSeconds = controllerSeconds
        clearLocalSettingApply("timeout")
        autoLockStatus = "Controller set to \(controllerSeconds)s"
    }

    private func reconcileServoAngles(in nextStatus: inout ControllerStatus) {
        clearRemoteSettingApplying()
        let controllerAngles = clampedServoAngles(nextStatus.servoAngles, using: nextStatus)

        if pendingServoAngles == controllerAngles {
            pendingServoAngles = nil
        }

        if inFlightServoAngles == controllerAngles {
            inFlightServoAngles = nil
        }

        let hasNewerLocalIntent = status.servoAngles != controllerAngles
            && (servoAnglesApplyTask != nil || pendingServoAngles != nil || inFlightServoAngles != nil)

        guard !hasNewerLocalIntent else {
            nextStatus.lockAngle = status.lockAngle
            nextStatus.unlockAngle = status.unlockAngle
            servoAnglesStatus = canSendDoorCommand ? "Setting..." : "Waiting for controller"
            return
        }

        nextStatus.lockAngle = controllerAngles.lockAngle
        nextStatus.unlockAngle = controllerAngles.unlockAngle
        clearLocalSettingApply("servo_angles")
        servoAnglesStatus = "Controller set to \(controllerAngles.lockAngle)° / \(controllerAngles.unlockAngle)°"
    }

    private func clampedServoAngles(_ angles: ServoAngles, using status: ControllerStatus? = nil) -> ServoAngles {
        let range = (status ?? self.status).servoAngleRange
        return ServoAngles(
            lockAngle: min(max(angles.lockAngle, range.lowerBound), range.upperBound),
            unlockAngle: min(max(angles.unlockAngle, range.lowerBound), range.upperBound)
        )
    }

    private func servoAnglesAreValid(_ angles: ServoAngles) -> Bool {
        servoAnglesAreValid(angles, using: status)
    }

    private func servoAnglesAreValid(_ angles: ServoAngles, using status: ControllerStatus) -> Bool {
        let range = status.servoAngleRange
        let gap = abs(angles.lockAngle - angles.unlockAngle)
        return range.contains(angles.lockAngle)
            && range.contains(angles.unlockAngle)
            && gap >= max(1, status.servoMinAngleGap)
    }

    private func autoLockDeadlineChanged(from oldDeadline: Date?, to newDeadline: Date?) -> Bool {
        switch (oldDeadline, newDeadline) {
        case (.none, .none):
            return false
        case let (.some(oldDeadline), .some(newDeadline)):
            return abs(oldDeadline.timeIntervalSince(newDeadline)) > 1
        default:
            return true
        }
    }

    private func startStateSyncLoop() {
        syncTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await self?.syncControllerStateIfNeeded()
            }
        }
    }

    func updateLockName(_ name: String) {
        let sanitizedName = Self.sanitizedLockName(name)
        guard !sanitizedName.isEmpty else { return }

        if sanitizedName != lockName {
            lockName = sanitizedName
            UserDefaults.standard.set(sanitizedName, forKey: Self.lockNameKey)
        }

        beginLocalSettingApply("lock_name")
        pendingLockName = sanitizedName
        lockNameStatus = canSendDoorCommand ? "Setting..." : "Waiting for controller"
        Task { await applyPendingLockName() }
    }

    private static func loadLockName() -> String {
        guard let savedName = UserDefaults.standard.string(forKey: lockNameKey) else {
            return defaultLockName
        }

        let sanitizedName = sanitizedLockName(savedName)
        return sanitizedName.isEmpty ? defaultLockName : sanitizedName
    }

    private static func sanitizedLockName(_ name: String) -> String {
        DoorDeviceNameNormalizer.normalized(name, fallback: defaultLockName)
    }

    private static func loadCachedStatus() -> ControllerStatus {
        let state: String = {
            switch UserDefaults.standard.string(forKey: cachedBleStateKey) {
            case "unlocked", "unlocking":
                return "unlocked"
            case "locked", "locking":
                return "locked"
            default:
                return "unknown"
            }
        }()

        let autoLockSeconds = UserDefaults.standard.object(forKey: cachedAutoLockSecondsKey) == nil
            ? ControllerStatus().autoLockSeconds
            : UserDefaults.standard.integer(forKey: cachedAutoLockSecondsKey)
        let lockAngle = UserDefaults.standard.object(forKey: cachedLockAngleKey) == nil
            ? ControllerStatus.defaultLockAngle
            : UserDefaults.standard.integer(forKey: cachedLockAngleKey)
        let unlockAngle = UserDefaults.standard.object(forKey: cachedUnlockAngleKey) == nil
            ? ControllerStatus.defaultUnlockAngle
            : UserDefaults.standard.integer(forKey: cachedUnlockAngleKey)
        let pairedCount = UserDefaults.standard.object(forKey: cachedPairedCountKey) == nil
            ? (UserDefaults.standard.bool(forKey: trustedMacControllerKey) ? 1 : 0)
            : UserDefaults.standard.integer(forKey: cachedPairedCountKey)
        let maxPairs = UserDefaults.standard.object(forKey: cachedMaxPairsKey) == nil
            ? ControllerStatus().maxPairs
            : UserDefaults.standard.integer(forKey: cachedMaxPairsKey)
        let maxConnections = UserDefaults.standard.object(forKey: cachedMaxConnectionsKey) == nil
            ? ControllerStatus().maxConnections
            : UserDefaults.standard.integer(forKey: cachedMaxConnectionsKey)

        return ControllerStatus(
            firmwareVersion: UserDefaults.standard.string(forKey: cachedFirmwareVersionKey) ?? ControllerStatus().firmwareVersion,
            lockName: loadLockName(),
            pairedCount: max(0, pairedCount),
            maxPairs: max(0, maxPairs),
            maxConnections: max(4, maxConnections),
            bleState: state,
            isUnlocked: state == "unlocked",
            autoLockSeconds: min(max(autoLockSeconds, minimumAutoLockSeconds), maximumAutoLockSeconds),
            lockAngle: min(max(lockAngle, ControllerStatus.defaultServoMinAngle), ControllerStatus.defaultServoMaxAngle),
            unlockAngle: min(max(unlockAngle, ControllerStatus.defaultServoMinAngle), ControllerStatus.defaultServoMaxAngle)
        )
    }

    private func saveCachedStatus(_ status: ControllerStatus) {
        let cacheableStatus = statusRemovingLocalUSBConnection(status)

        switch cacheableStatus.bleState {
        case "locked", "unlocked", "locking", "unlocking":
            UserDefaults.standard.set(cacheableStatus.bleState, forKey: Self.cachedBleStateKey)
        default:
            break
        }

        UserDefaults.standard.set(Self.sanitizedLockName(cacheableStatus.lockName), forKey: Self.lockNameKey)
        UserDefaults.standard.set(cacheableStatus.autoLockSeconds, forKey: Self.cachedAutoLockSecondsKey)
        UserDefaults.standard.set(cacheableStatus.lockAngle, forKey: Self.cachedLockAngleKey)
        UserDefaults.standard.set(cacheableStatus.unlockAngle, forKey: Self.cachedUnlockAngleKey)
        UserDefaults.standard.set(max(0, cacheableStatus.pairedCount), forKey: Self.cachedPairedCountKey)
        UserDefaults.standard.set(max(0, cacheableStatus.maxPairs), forKey: Self.cachedMaxPairsKey)
        UserDefaults.standard.set(max(4, cacheableStatus.maxConnections), forKey: Self.cachedMaxConnectionsKey)
        UserDefaults.standard.set(cacheableStatus.firmwareVersion, forKey: Self.cachedFirmwareVersionKey)
    }

    private func applyControllerLockName(_ name: String) {
        clearRemoteSettingApplying()
        let sanitizedName = Self.sanitizedLockName(name)
        guard !sanitizedName.isEmpty else { return }

        if inFlightLockName == sanitizedName {
            inFlightLockName = nil
        }
        if pendingLockName == sanitizedName {
            pendingLockName = nil
        }

        let hasNewerLocalIntent = lockName != sanitizedName && (pendingLockName != nil || inFlightLockName != nil)
        guard !hasNewerLocalIntent else {
            lockNameStatus = canSendDoorCommand ? "Setting..." : "Waiting for controller"
            if pendingLockName != nil {
                Task { await applyPendingLockName() }
            }
            return
        }

        lockName = sanitizedName
        UserDefaults.standard.set(sanitizedName, forKey: Self.lockNameKey)
        clearLocalSettingApply("lock_name")
        lockNameStatus = "Controller name set"

        if pendingLockName != nil {
            Task { await applyPendingLockName() }
        }
    }

    private func applyPendingLockName() async {
        guard let name = pendingLockName else {
            if inFlightLockName == nil {
                clearLocalSettingApply("lock_name")
            }
            return
        }

        if isBusy && isConnected {
            schedulePendingLockNameRetry()
            return
        }

        if isConnected {
            inFlightLockName = name
            pendingLockName = nil
            lockNameStatus = "Setting..."
            sendStatusCommand("app lock name \(name)", label: "Lock name", timeout: 10, refreshPairsAfterSuccess: false)
            return
        }

        if isWirelessReady {
            inFlightLockName = name
            pendingLockName = nil
            lockNameStatus = "Setting..."
            if !sendWirelessCommandText("SET_LOCK_NAME:\(name)", intent: .lockName(name)) {
                inFlightLockName = nil
                pendingLockName = name
                lockNameStatus = "Not set"
            }
            return
        }

        inFlightLockName = name
        pendingLockName = nil
        lockNameStatus = "Setting..."
        queueWirelessCommand("SET_LOCK_NAME:\(name)", intent: .lockName(name))
    }

    private func schedulePendingLockNameRetry() {
        lockNameApplyTask?.cancel()
        lockNameApplyTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 750_000_000)
            await MainActor.run {
                self?.lockNameApplyTask = nil
            }
            await self?.applyPendingLockName()
        }
    }

    private func syncControllerStateIfNeeded() async {
        refreshUSBPortsIfNeeded()

        let shouldConfirmExpiredAutoLock = updateLocalAutoLockCountdown()

        if isConnected, !isBusy {
            let now = Date()
            let isUSBPollDue = lastUSBStatusSyncAt.map { now.timeIntervalSince($0) >= 2 } ?? true
            let shouldPollUSB = shouldConfirmExpiredAutoLock || isUSBPollDue
            if shouldPollUSB {
                lastUSBStatusSyncAt = now
                if shouldConfirmExpiredAutoLock {
                    hasConfirmedExpiredAutoLockDeadline = true
                }
                await silentlySyncUSBStatus()
            }

            await syncPairedDevicesIfNeeded(now: now)
            return
        }

        guard central?.state == .poweredOn, canUseWirelessFallback else { return }

        if !isWirelessSessionActive {
            return
        }

        guard isWirelessGattReady else { return }

        if isWirelessStateNotificationEnabled {
            guard shouldConfirmExpiredAutoLock else { return }
            lastWirelessStateSyncAt = Date()
            hasConfirmedExpiredAutoLockDeadline = true
            readStateIfPossible()
            return
        }

        let now = Date()
        let isWirelessPollDue = lastWirelessStateSyncAt.map { now.timeIntervalSince($0) >= Self.wirelessStatePollInterval } ?? true
        guard shouldConfirmExpiredAutoLock || isWirelessPollDue else { return }

        lastWirelessStateSyncAt = now
        if shouldConfirmExpiredAutoLock {
            hasConfirmedExpiredAutoLockDeadline = true
        }
        readStateIfPossible()
    }

    private func updateLocalAutoLockCountdown() -> Bool {
        guard status.isUnlocked, let deadline = status.autoLockDeadline else {
            return false
        }

        let remainingSeconds = Int(ceil(deadline.timeIntervalSinceNow))
        if remainingSeconds > 0 {
            if status.autoLockRemainingSeconds != remainingSeconds {
                var nextStatus = status
                nextStatus.autoLockRemainingSeconds = remainingSeconds
                status = nextStatus
            }
            return false
        }

        var nextStatus = status
        nextStatus.bleState = "locked"
        nextStatus.isUnlocked = false
        nextStatus.autoLockRemainingSeconds = nil
        nextStatus.autoLockDeadline = nil
        status = nextStatus
        saveCachedStatus(nextStatus)
        message = "Door locked"
        return !hasConfirmedExpiredAutoLockDeadline
    }

    private func silentlySyncUSBStatus() async {
        guard !isSilentStatusSyncInFlight else { return }
        isSilentStatusSyncInFlight = true
        defer { isSilentStatusSyncInFlight = false }

        do {
            let statusLines = try await transact("app status", until: ["APP_STATUS_END"], timeout: 2)
            let nextStatus = DoorSerialParser.parseStatus(from: statusLines)
            if nextStatus != status {
                applyControllerStatus(nextStatus)
                message = statusMessage(for: nextStatus)
            }
        } catch {
            guard isConnected else { return }
            if !selectedUSBPortStillPresent() {
                markUSBDisconnected(reason: "USB-C disconnected")
                return
            }
            lastError = error.localizedDescription
        }
    }

    private func syncPairedDevicesIfNeeded(now: Date) async {
        let isPairCountStale = status.pairedCount != pairedDevices.count
        let secondsSinceLastSync = lastPairedDevicesSyncAt.map { now.timeIntervalSince($0) }
        let isPairListDue = secondsSinceLastSync.map { $0 >= Self.pairedDevicesSyncInterval } ?? true
        let canForceSyncForCountChange = isPairCountStale && (secondsSinceLastSync.map { $0 >= 1 } ?? true)

        guard canForceSyncForCountChange || isPairListDue else { return }

        do {
            try await loadPairedDevices(shouldLog: false)
        } catch {
            guard isConnected else { return }
            lastPairedDevicesSyncAt = now
            lastError = error.localizedDescription
        }
    }

    private func successMessage(for label: String, status: ControllerStatus) -> String {
        switch label {
        case "Lock":
            return "Door locked"
        case "Unlock":
            return "Door unlocked"
        case "Allow New Device":
            return "Ready to add a device"
        case "Stop Pairing":
            return "Pairing closed"
        case "Approve Device":
            return "Device trusted"
        case "Reject Device":
            return "Pairing request rejected"
        case "Remove Device":
            return "Device removed"
        case "Clear Devices":
            return "Trusted devices cleared"
        case "Rename Device":
            return "Device renamed"
        case "Auto-lock":
            return "Auto-lock updated"
        case "Servo angles":
            return "Servo angles updated"
        default:
            return statusMessage(for: status)
        }
    }

    private func statusMessage(for status: ControllerStatus) -> String {
        if status.hasPendingRequest {
            return "Device waiting for approval"
        }

        switch status.bleState {
        case "unlocked", "unlocking":
            return "Door unlocked"
        case "locked", "locking":
            return "Door locked"
        case "pairing_enabled":
            return "Ready to add a device"
        case "pairing_pending":
            return "Device waiting for approval"
        case "pairing_locked":
            return "Pairing closed"
        default:
            return isConnected ? "Controller ready" : "Disconnected"
        }
    }

    private static func cachedStartupMessage() -> String {
        let status = loadCachedStatus()
        if status.hasPendingRequest {
            return "Device waiting for approval"
        }

        switch status.bleState {
        case "unlocked", "unlocking":
            return "Door unlocked"
        case "locked", "locking":
            return "Door locked"
        case "pairing_enabled":
            return "Ready to add a device"
        case "pairing_pending":
            return "Device waiting for approval"
        case "pairing_locked":
            return "Pairing closed"
        default:
            let hasTrustedController = UserDefaults.standard.bool(forKey: trustedMacControllerKey)
            let hasKnownController = UserDefaults.standard.string(forKey: knownPeripheralIdentifierKey) != nil
            return hasTrustedController && hasKnownController ? "Opening saved controller" : "Disconnected"
        }
    }

    private func transact(_ command: String, until markers: Set<String>, timeout: TimeInterval) async throws -> [String] {
        guard let connection else { throw DoorAdminError.notConnected }
        return try await serialGate.transact(connection: connection, command: command, until: markers, timeout: timeout)
    }

    private func appendLog(_ lines: [String]) {
        logLines.append(contentsOf: lines.map(redactedLogLine))
        if logLines.count > 120 {
            logLines.removeFirst(logLines.count - 120)
        }
    }

    private func redactedLogLine(_ line: String) -> String {
        let sensitivePrefixes = [
            "Code:",
            "Fingerprint:",
            "Expected code:",
            "Expected fingerprint:",
            "pending_fingerprint="
        ]

        if sensitivePrefixes.contains(where: { line.hasPrefix($0) }) {
            return "[pairing confirmation hidden]"
        }
        return line
    }

    private func connect(to peripheral: CBPeripheral) {
        guard let central else { return }
        guard canUseWirelessFallback else {
            stopWirelessSession(reason: wirelessStopReason)
            return
        }

        saveKnownPeripheral(peripheral)

        if self.peripheral?.identifier == peripheral.identifier {
            if peripheral.state == .connected {
                if !isWirelessGattReady {
                    peripheral.discoverServices([serviceUUID])
                }
                return
            }
            if peripheral.state == .connecting {
                scheduleKnownPeripheralDiscoveryRetry()
                return
            }
        } else if let currentPeripheral = self.peripheral,
                  currentPeripheral.state == .connecting || currentPeripheral.state == .connected {
            central.cancelPeripheralConnection(currentPeripheral)
        }

        commandCharacteristic = nil
        stateCharacteristic = nil
        pairingCharacteristic = nil
        controlCharacteristic = nil
        isWirelessStateNotificationEnabled = false
        wirelessControlNonceRecoveryTask?.cancel()
        wirelessControlNonceRecoveryTask = nil
        invalidatePreparedFastDoorCommandPayloads(clearNonce: true)
        wirelessPairingState = "Unknown"
        lastWirelessStateSyncAt = nil
        self.peripheral = peripheral
        self.peripheral?.delegate = self

        if peripheral.state == .connected {
            wirelessConnectionState = isWirelessGattReady ? "Ready" : "Discovering"
            stopWirelessScan()
            peripheral.discoverServices([serviceUUID])
            scheduleKnownPeripheralDiscoveryRetry()
            return
        }

        wirelessConnectionState = "Connecting"
        recordRuntimeTelemetry("connect_start")
        stopWirelessScan()
        central.connect(peripheral, options: nil)
        scheduleKnownPeripheralDiscoveryRetry()
    }

    private func saveKnownPeripheral(_ peripheral: CBPeripheral) {
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.knownPeripheralIdentifierKey)
    }

    private func isCurrentPeripheral(_ peripheral: CBPeripheral) -> Bool {
        self.peripheral?.identifier == peripheral.identifier
    }

    private func connectToKnownPeripheralIfPossible() -> Bool {
        guard let central else {
            return false
        }

        if let identifierText = UserDefaults.standard.string(forKey: Self.knownPeripheralIdentifierKey),
           let identifier = UUID(uuidString: identifierText),
           let knownPeripheral = central.retrievePeripherals(withIdentifiers: [identifier]).first,
           knownPeripheral.state != .disconnecting {
            recordRuntimeTelemetry("known_peripheral_retrieved", details: "state=\(knownPeripheral.state.rawValue)")
            restoreOrConnectToKnownPeripheral(knownPeripheral, central: central)
            return true
        }

        let connectedDoorPeripherals = central.retrieveConnectedPeripherals(withServices: [serviceUUID])
        guard let connectedPeripheral = connectedDoorPeripherals.first(where: { $0.state == .connected || $0.state == .connecting })
            ?? connectedDoorPeripherals.first else {
            return false
        }

        recordRuntimeTelemetry("connected_peripheral_retrieved", details: "state=\(connectedPeripheral.state.rawValue)")
        restoreOrConnectToKnownPeripheral(connectedPeripheral, central: central)
        return true
    }

    private func restoreOrConnectToKnownPeripheral(_ knownPeripheral: CBPeripheral, central: CBCentralManager) {
        saveKnownPeripheral(knownPeripheral)
        peripheral = knownPeripheral
        peripheral?.delegate = self
        wirelessConnectionState = knownPeripheral.state == .connected ? "Discovering" : "Reconnecting"
        stopWirelessScan()

        switch knownPeripheral.state {
        case .connected:
            markWirelessConnectionObserved()
            knownPeripheral.discoverServices([serviceUUID])
        case .connecting:
            break
        case .disconnected:
            central.connect(knownPeripheral, options: nil)
        case .disconnecting:
            return
        @unknown default:
            central.connect(knownPeripheral, options: nil)
        }

        scheduleKnownPeripheralDiscoveryRetry()
    }

    private func scheduleKnownPeripheralDiscoveryRetry() {
        wirelessKnownPeripheralFallbackTask?.cancel()
        wirelessKnownPeripheralFallbackTask = Task { [weak self] in
            let nanoseconds = UInt64(Self.knownPeripheralDiscoveryRetryDelay * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            await MainActor.run {
                guard let self,
                      self.central?.state == .poweredOn,
                      self.canUseWirelessFallback,
                      !self.isWirelessGattReady else {
                    return
                }

                if let peripheral = self.peripheral,
                   peripheral.state == .connected {
                    peripheral.discoverServices([self.serviceUUID])
                    return
                }

                if let peripheral = self.peripheral,
                   peripheral.state == .connecting {
                    self.wirelessConnectionState = "Connecting"
                    self.scheduleKnownPeripheralDiscoveryRetry()
                    return
                }

                self.wirelessConnectionState = "Scanning"
                self.startWirelessScanIfNeeded()
            }
        }
    }

    private func scanOptionsForCurrentMode(allowsDuplicates: Bool = false) -> [String: Any] {
        [
            CBCentralManagerScanOptionAllowDuplicatesKey: allowsDuplicates
        ]
    }

    private func nextWirelessReconnectDelay() -> TimeInterval {
        let index = min(wirelessReconnectAttempt, Self.wirelessReconnectDelays.count - 1)
        wirelessReconnectAttempt += 1
        return Self.wirelessReconnectDelays[index]
    }

    private func scheduleWirelessReconnect(after delay: TimeInterval = 1, stateTitle: String = "Reconnecting") {
        wirelessReconnectTask?.cancel()
        wirelessConnectionState = stateTitle
        wirelessReconnectTask = Task { [weak self] in
            let nanoseconds = UInt64(max(0, delay) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            await MainActor.run {
                guard let self,
                      self.central?.state == .poweredOn,
                      self.canUseWirelessFallback,
                      !self.isWirelessGattReady else {
                    return
                }

                self.scanBluetooth()
            }
        }
    }

    private func scheduleWirelessIdleDisconnect(after delay: TimeInterval = 1.2) {
        wirelessIdleDisconnectTask?.cancel()
        wirelessIdleDisconnectTask = nil

        guard !hasTrustedMacController else {
            return
        }

        wirelessIdleDisconnectTask = Task { [weak self] in
            let nanoseconds = UInt64(max(0, delay) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            await MainActor.run {
                guard let self,
                      !self.isConnected,
                      self.canUseWirelessFallback,
                      self.pendingWirelessCommandText == nil,
                      self.pendingWirelessWriteIntents.isEmpty else {
                    return
                }

                self.stopWirelessSession(reason: "Idle")
            }
        }
    }

    private func stopWirelessSession(reason: String) {
        wirelessReconnectTask?.cancel()
        wirelessReconnectTask = nil
        wirelessIdleDisconnectTask?.cancel()
        wirelessIdleDisconnectTask = nil
        wirelessKnownPeripheralFallbackTask?.cancel()
        wirelessKnownPeripheralFallbackTask = nil
        wirelessStateSnapshotFallbackTask?.cancel()
        wirelessStateSnapshotFallbackTask = nil
        wirelessControlNonceRecoveryTask?.cancel()
        wirelessControlNonceRecoveryTask = nil
        stopSecureLinkWatchdog()
        stopWirelessScan()
        if let peripheral, peripheral.state == .connected || peripheral.state == .connecting {
            central?.cancelPeripheralConnection(peripheral)
        }
        pendingWirelessWriteIntents = []
        fastDoorCommandInFlight = nil
        invalidatePreparedFastDoorCommandPayloads(clearNonce: true)
        lastWirelessStateSyncAt = nil
        isWirelessStateNotificationEnabled = false
        peripheral = nil
        commandCharacteristic = nil
        stateCharacteristic = nil
        pairingCharacteristic = nil
        controlCharacteristic = nil
        wirelessConnectionState = reason
        wirelessPairingState = isConnected ? "USB-C active" : "Unknown"
    }

    private func readStateIfPossible() {
        guard let peripheral, let stateCharacteristic else { return }
        if stateCharacteristic.properties.contains(.read) {
            peripheral.readValue(for: stateCharacteristic)
        }
    }

    private func hasPendingDoorCharacteristicDiscovery(on peripheral: CBPeripheral) -> Bool {
        let doorServices = peripheral.services?.filter { $0.uuid == serviceUUID } ?? []
        return doorServices.contains { $0.characteristics == nil }
    }

    private func scheduleWirelessStateSnapshotFallbackRead(after delay: TimeInterval = 0.15) {
        wirelessStateSnapshotFallbackTask?.cancel()
        let generation = wirelessStateUpdateGeneration
        wirelessStateSnapshotFallbackTask = Task { [weak self] in
            let nanoseconds = UInt64(max(0, delay) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            await MainActor.run {
                guard let self,
                      self.wirelessStateUpdateGeneration == generation,
                      self.isWirelessGattReady else {
                    return
                }

                self.wirelessStateSnapshotFallbackTask = nil
                self.readStateIfPossible()
            }
        }
    }

    private func readAckIfPossible() {
        guard let peripheral, let controlCharacteristic else { return }
        if controlCharacteristic.properties.contains(.read) {
            peripheral.readValue(for: controlCharacteristic)
        }
    }

    private func enableWirelessControlNotificationsIfPossible(on peripheral: CBPeripheral) {
        guard isCurrentPeripheral(peripheral),
              let controlCharacteristic else {
            return
        }

        if (controlCharacteristic.properties.contains(.notify) || controlCharacteristic.properties.contains(.indicate)),
           !controlCharacteristic.isNotifying {
            peripheral.setNotifyValue(true, for: controlCharacteristic)
        } else {
            scheduleWirelessControlNonceRecoveryIfNeeded()
        }
    }

    private func requestWirelessControlNonce() {
        guard let peripheral,
              let controlCharacteristic else {
            startSecureLinkWatchdogIfNeeded()
            return
        }

        recordRuntimeTelemetry("secure_nonce_requested", once: false)
        if (controlCharacteristic.properties.contains(.notify) || controlCharacteristic.properties.contains(.indicate)),
           !controlCharacteristic.isNotifying {
            peripheral.setNotifyValue(true, for: controlCharacteristic)
        } else if controlCharacteristic.properties.contains(.notify) || controlCharacteristic.properties.contains(.indicate) {
            readAckIfPossible()
            scheduleWirelessControlNonceRecoveryIfNeeded(after: 0.25)
        } else {
            readAckIfPossible()
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

    private func scheduleWirelessControlNonceRecoveryIfNeeded(after delay: TimeInterval = 0.08) {
        guard isWirelessGattReady,
              !isWirelessDoorCommandReady,
              fastCommandNonce == nil,
              (controlCharacteristic?.properties.contains(.notify) == true ||
                controlCharacteristic?.properties.contains(.indicate) == true) else {
            return
        }

        wirelessControlNonceRecoveryTask?.cancel()
        let generation = wirelessControlUpdateGeneration
        wirelessControlNonceRecoveryTask = Task { [weak self] in
            let firstDelay = UInt64(max(0, delay) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: firstDelay)
            await MainActor.run {
                guard let self,
                      self.wirelessControlUpdateGeneration == generation,
                      self.isWirelessGattReady,
                      !self.isWirelessDoorCommandReady,
                      self.fastCommandNonce == nil,
                      let peripheral = self.peripheral,
                      let controlCharacteristic = self.controlCharacteristic else {
                    return
                }

                if controlCharacteristic.isNotifying {
                    self.readAckIfPossible()
                    self.wirelessControlNonceRecoveryTask = nil
                } else {
                    peripheral.setNotifyValue(true, for: controlCharacteristic)
                    self.wirelessControlNonceRecoveryTask = nil
                }
            }
        }
    }

    private func startSecureLinkWatchdogIfNeeded() {
        guard secureLinkWatchdogTask == nil,
              needsFreshSecureNonce else {
            return
        }

        secureLinkWatchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                let shouldContinue = await MainActor.run { () -> Bool in
                    guard let self else { return false }
                    return self.needsFreshSecureNonce
                }

                guard shouldContinue else { break }

                await MainActor.run {
                    guard let self,
                          self.needsFreshSecureNonce,
                          self.peripheral != nil,
                          self.controlCharacteristic != nil else {
                        return
                    }

                    self.requestWirelessControlNonceWithoutWatchdog()
                }

                try? await Task.sleep(nanoseconds: 250_000_000)
            }

            await MainActor.run {
                self?.secureLinkWatchdogTask = nil
            }
        }
    }

    private var needsFreshSecureNonce: Bool {
        isWirelessReady &&
            fastCommandNonce == nil &&
            ((pendingFirmwareUpdatePackageURL != nil && !firmwareUpdateEntryCommandSent) ||
                pendingWirelessCommandText != nil ||
                preparedFastDoorCommandPayloads.isEmpty)
    }

    private func requestWirelessControlNonceWithoutWatchdog() {
        guard let peripheral,
              let controlCharacteristic else {
            return
        }

        recordRuntimeTelemetry("secure_nonce_requested", once: false)
        if (controlCharacteristic.properties.contains(.notify) || controlCharacteristic.properties.contains(.indicate)),
           !controlCharacteristic.isNotifying {
            peripheral.setNotifyValue(true, for: controlCharacteristic)
        } else if controlCharacteristic.properties.contains(.notify) || controlCharacteristic.properties.contains(.indicate) {
            readAckIfPossible()
            scheduleWirelessControlNonceRecoveryIfNeeded(after: 0.25)
        } else {
            readAckIfPossible()
        }
        requestNonceViaCommandIfPossible()
    }

    private func stopSecureLinkWatchdog() {
        secureLinkWatchdogTask?.cancel()
        secureLinkWatchdogTask = nil
        wirelessControlNonceRecoveryTask?.cancel()
        wirelessControlNonceRecoveryTask = nil
    }

    private func markWirelessConnectionObserved() {
        guard !isConnected else { return }
        var nextStatus = status
        nextStatus.connectedCount = max(nextStatus.connectedCount, 1)
        nextStatus.maxConnections = max(nextStatus.maxConnections, 4)
        status = nextStatus
    }

    private func prepareFastDoorCommandPayloads(for nonce: Data) {
        preparedFastDoorCommandGeneration += 1
        let generation = preparedFastDoorCommandGeneration
        let commandOrder = fastDoorCommandPreparationOrder()

        preparedFastDoorCommandTask?.cancel()
        preparedFastDoorCommandTask = Task { [weak self] in
            for command in commandOrder {
                let payload = try? await Task.detached(priority: .userInitiated) {
                    try DoorCommandAuthenticator.fastCommandPayload(
                        for: command.authenticatorFastCommand,
                        nonce: nonce
                    )
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
                    }
                    return
                }

                let shouldContinue = await MainActor.run {
                    guard let self,
                          self.preparedFastDoorCommandGeneration == generation,
                          self.fastCommandNonce == nonce,
                          self.hasTrustedMacController else {
                        return false
                    }

                    self.preparedFastDoorCommandPayloads[command] = payload
                    if self.preparedFastDoorCommandPayloads.count == 1 {
                        self.recordRuntimeTelemetry("first_fast_payload_ready", details: command.rawValue)
                        self.recordRuntimeTelemetry("door_command_usable", details: "fast_payload_ready")
                    }
                    self.sendQueuedWirelessCommand()
                    return self.preparedFastDoorCommandGeneration == generation &&
                        self.fastCommandNonce == nonce
                }

                guard shouldContinue else { return }
            }

            await MainActor.run {
                guard let self,
                      self.preparedFastDoorCommandGeneration == generation,
                      self.fastCommandNonce == nonce,
                      self.hasTrustedMacController else {
                    return
                }

                self.preparedFastDoorCommandTask = nil
                self.sendQueuedWirelessCommand()
            }
        }
    }

    private func fastDoorCommandPreparationOrder() -> [Command] {
        let first = pendingWirelessPredictedCommand ?? (status.isUnlocked ? .lock : .unlock)
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
        firmwareLog.info("Secure nonce received pendingFirmware=\(self.pendingFirmwareUpdatePackageURL != nil, privacy: .public)")
        stopSecureLinkWatchdog()
        fastCommandNonce = nonce
        recordRuntimeTelemetry("secure_nonce_received")
        recordRuntimeTelemetry("door_command_usable", details: "nonce_ready")
        if sendPendingFirmwareUpdateCommandIfReady() {
            return
        }
        if sendQueuedWirelessNonDoorCommandIfReady() {
            return
        }
        prepareFastDoorCommandPayloads(for: nonce)
    }

    @discardableResult
    private func sendQueuedWirelessNonDoorCommandIfReady() -> Bool {
        guard pendingWirelessCommandText != nil,
              !hasQueuedWirelessDoorCommand else {
            return false
        }

        sendQueuedWirelessCommand()
        return true
    }

    private var hasQueuedWirelessDoorCommand: Bool {
        guard let pendingWirelessCommandIntent else { return false }
        if case .doorCommand = pendingWirelessCommandIntent {
            return true
        }

        return false
    }

    private func applyWirelessState(_ newState: String) {
        if let applying = Self.settingApplying(from: newState) {
            applyRemoteSettingApplying(kind: applying.kind, value: applying.value)
            updateWirelessPairingState(from: "paired")
            return
        }

        if let controllerLockName = Self.lockName(from: newState) {
            applyControllerLockName(controllerLockName)
            updateWirelessPairingState(from: "paired")
            return
        }

        if let controllerAngles = Self.servoAngles(from: newState) {
            var nextStatus = status
            nextStatus.lockAngle = controllerAngles.lockAngle
            nextStatus.unlockAngle = controllerAngles.unlockAngle
            reconcileServoAngles(in: &nextStatus)
            status = nextStatus
            saveCachedStatus(nextStatus)
            updateWirelessPairingState(from: "paired")
            return
        }

        if let lastUnlock = Self.lastUnlockRecord(from: newState) {
            var nextStatus = status
            nextStatus.lastUnlockAt = lastUnlock.unlockedAt
            nextStatus.lastUnlockDeviceIdentifier = lastUnlock.deviceIdentifier
            nextStatus.lastUnlockDeviceName = lastUnlock.deviceName
            status = nextStatus
            saveCachedStatus(nextStatus)
            updateWirelessPairingState(from: "paired")
            return
        }

        if let controllerFirmwareVersion = Self.firmwareVersion(from: newState) {
            var nextStatus = status
            nextStatus.firmwareVersion = controllerFirmwareVersion
            status = nextStatus
            saveCachedStatus(nextStatus)
            if firmwareUpdateStatus == "Update complete. Verifying..." {
                firmwareUpdateStatus = "Verified \(controllerFirmwareVersion)"
            }
            updateWirelessPairingState(from: "paired")
            return
        }

        if let updateState = Self.firmwareUpdateState(from: newState) {
            if updateState == "ota_dfu" {
                firmwareUpdateStatus = "Controller entering update mode"
                if let packageURL = pendingFirmwareUpdatePackageURL {
                    pendingFirmwareUpdatePackageURL = nil
                    firmwareUpdateEntryCommandSent = false
                    beginFirmwareDfuUpload(after: packageURL)
                }
            }
            updateWirelessPairingState(from: "paired")
            return
        }

        if let connections = Self.connectedDevices(from: newState) {
            var nextStatus = status
            nextStatus.connectedCount = connections.count
            nextStatus.maxConnections = connections.max
            nextStatus.connectedDevices = connections.devices
            status = statusIncludingLocalUSBConnection(nextStatus)
            saveCachedStatus(status)
            if wirelessPairingState == "Unknown", isWirelessReady, status.pairedCount > 0 {
                updateWirelessPairingState(from: "paired")
            }
            return
        }

        let payload = ControllerStatePayload.parse(newState)
        if payload.state == "timeout_set" {
            if let seconds = payload.remainingSeconds {
                var nextStatus = status
                nextStatus.autoLockSeconds = seconds
                if nextStatus.isUnlocked {
                    nextStatus.autoLockRemainingSeconds = seconds
                    nextStatus.autoLockDeadline = Date().addingTimeInterval(TimeInterval(seconds))
                    hasConfirmedExpiredAutoLockDeadline = false
                }
                reconcileAutoLockSeconds(in: &nextStatus)
                status = nextStatus
                saveCachedStatus(nextStatus)
            }
            updateWirelessPairingState(from: payload.state)
            return
        }

        if payload.state == "paired" {
            clearRemoteSettingApplying()
            updateWirelessPairingState(from: payload.state)
            if isConnected, !isBusy {
                Task { [weak self] in
                    try? await self?.loadPairedDevices()
                }
            }
            return
        }

        let deadline = payload.remainingSeconds.map {
            Date().addingTimeInterval(TimeInterval(max(0, $0)))
        }
        var nextStatus = status
        nextStatus.bleState = payload.state
        nextStatus.isUnlocked = payload.state == "unlocked" || payload.state == "unlocking"
        nextStatus.autoLockRemainingSeconds = nextStatus.isUnlocked ? payload.remainingSeconds : nil
        nextStatus.autoLockDeadline = nextStatus.isUnlocked ? deadline : nil
        if payload.state == "rejected" {
            clearRemoteSettingApplying()
        }
        status = nextStatus
        saveCachedStatus(nextStatus)
        if payload.state == "locked" ||
            payload.state == "unlocked" ||
            payload.state == "locking" ||
            payload.state == "unlocking" {
            fastDoorCommandInFlight = nil
        }
        hasConfirmedExpiredAutoLockDeadline = false
        message = statusMessage(for: status)
        updateWirelessPairingState(from: payload.state)
    }

    private func handleFastCommandReject(reason: String) {
        invalidatePreparedFastDoorCommandPayloads(clearNonce: true)

        switch reason {
        case "busy":
            lastError = "Controller is busy."
        case "bad_nonce", "missing_nonce":
            if let command = fastDoorCommandInFlight {
                pendingWirelessCommandText = command.commandText
                pendingWirelessPredictedCommand = command
                pendingWirelessCommandIntent = .doorCommand
            }
            message = "Refreshing secure control"
            lastError = nil
            requestWirelessControlNonce()
        case "bad_signature", "unpaired":
            lastError = "Controller rejected the command."
        default:
            lastError = "Controller rejected the command."
        }

        fastDoorCommandInFlight = nil
        readStateIfPossible()
    }

    private func updateWirelessPairingState(from state: String) {
        switch state {
        case "pairing_enabled":
            wirelessPairingState = "Pairing enabled"
        case "pairing_pending":
            wirelessPairingState = "Pairing pending"
        case "pairing_locked", "unpaired":
            wirelessPairingState = "Pairing locked"
            setTrustedMacController(false)
        case "paired", "locked", "unlocked", "locking", "unlocking", "timeout_set", "last_unlock":
            wirelessPairingState = hasTrustedMacController ? "Ready" : "USB-C trust needed"
        case "rejected":
            wirelessPairingState = hasTrustedMacController ? "Ready" : "USB-C trust needed"
            lastError = "Controller rejected the command. Pair this Mac over USB-C if it keeps happening."
        default:
            break
        }
    }

    private static func lockName(from state: String) -> String? {
        let prefix = "lock_name:"
        guard state.hasPrefix(prefix) else { return nil }

        let rawName = String(state.dropFirst(prefix.count))
        let sanitizedName = sanitizedLockName(rawName)
        return sanitizedName.isEmpty ? nil : sanitizedName
    }

    private static func firmwareVersion(from state: String) -> String? {
        let prefix = "firmware_version:"
        guard state.hasPrefix(prefix) else { return nil }

        let value = String(state.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func firmwareUpdateState(from state: String) -> String? {
        let prefix = "firmware_update:"
        guard state.hasPrefix(prefix) else { return nil }

        let value = String(state.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func fastCommandNonce(from state: String) -> Data? {
        let prefix = "nonce:v3:"
        guard state.hasPrefix(prefix) else { return nil }

        let hex = String(state.dropFirst(prefix.count))
        return dataFromHex(hex, expectedByteCount: 16)
    }

    private static func fastCommandRejectReason(from state: String) -> String? {
        let prefix = "reject:v3:"
        guard state.hasPrefix(prefix) else { return nil }

        let reason = String(state.dropFirst(prefix.count))
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

    private static func servoAngles(from state: String) -> ServoAngles? {
        let prefix = "servo_angles:"
        guard state.hasPrefix(prefix) else { return nil }

        let values = state.dropFirst(prefix.count)
            .split(separator: ",", maxSplits: 1)
            .compactMap { Int(String($0).trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard values.count == 2 else { return nil }
        return ServoAngles(lockAngle: values[0], unlockAngle: values[1])
    }

    private static func lastUnlockRecord(from state: String) -> LastUnlockRecord? {
        let prefix = "last_unlock:"
        guard state.hasPrefix(prefix) else { return nil }

        let payload = String(state.dropFirst(prefix.count))
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

    private static func connectedDevices(from state: String) -> (count: Int, max: Int, devices: [ConnectedControllerDevice])? {
        let prefix = "connections:"
        guard state.hasPrefix(prefix) else { return nil }

        let payload = String(state.dropFirst(prefix.count))
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
            return ConnectedControllerDevice(
                slot: index + 1,
                handle: "wireless-\(index + 1)",
                name: name,
                isTrustedName: true
            )
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

extension DoorAdminStore: DoorFirmwareDfuManagerDelegate {
    func firmwareDfuManagerDidUpdate(status: String, progress: Int?) {
        firmwareLog.info("DFU status=\(status, privacy: .public) progress=\(progress ?? -1, privacy: .public)")
        firmwareUpdateStatus = status
        firmwareUpdateProgress = progress
    }

    func firmwareDfuManagerDidFinish() {
        firmwareLog.info("DFU finished; verifying firmware version")
        firmwareUpdateWatchdogTask?.cancel()
        firmwareUpdateWatchdogTask = nil
        firmwareUpdateEntryCommandSent = false
        firmwareUpdateStatus = "Update complete. Verifying..."
        firmwareUpdateProgress = 100
        isFirmwareUpdateRunning = false
        wirelessIdleDisconnectTask?.cancel()
        wirelessIdleDisconnectTask = nil
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await MainActor.run {
                guard let self else { return }
                if self.isConnected {
                    self.refreshAll()
                } else {
                    self.scanBluetooth()
                }
            }
        }
    }

    func firmwareDfuManagerDidFail(_ message: String) {
        firmwareLog.error("DFU failed: \(message, privacy: .public)")
        firmwareUpdateWatchdogTask?.cancel()
        firmwareUpdateWatchdogTask = nil
        pendingFirmwareUpdatePackageURL = nil
        firmwareUpdateEntryCommandSent = false
        firmwareUpdateStatus = "Firmware update failed"
        firmwareUpdateProgress = nil
        isFirmwareUpdateRunning = false
        lastError = message
        scanBluetooth()
    }
}

extension DoorAdminStore: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            switch central.state {
            case .poweredOn:
                bluetoothState = "On"
                recordRuntimeTelemetry("bluetooth_powered_on")
                if canUseWirelessFallback && !isWirelessSessionActive {
                    scanBluetooth()
                } else if isConnected || isUSBConnectInFlight {
                    stopWirelessSession(reason: "USB-C active")
                } else {
                    stopWirelessSession(reason: "Idle")
                }
            case .poweredOff, .unauthorized, .unsupported, .resetting, .unknown:
                updateBluetoothAvailabilityState(central.state)
            @unknown default:
                updateBluetoothAvailabilityState(central.state)
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        Task { @MainActor in
            connect(to: peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            guard isCurrentPeripheral(peripheral) else {
                central.cancelPeripheralConnection(peripheral)
                return
            }

            wirelessKnownPeripheralFallbackTask?.cancel()
            wirelessKnownPeripheralFallbackTask = nil
            saveKnownPeripheral(peripheral)
            markWirelessConnectionObserved()
            wirelessConnectionState = "Discovering"
            recordRuntimeTelemetry("peripheral_connected")
            peripheral.discoverServices([serviceUUID])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            guard isCurrentPeripheral(peripheral) else { return }

            if Self.isBluetoothEncryptionError(error) {
                lastError = nil
                scheduleWirelessReconnect(
                    after: Self.wirelessEncryptionRecoveryDelay,
                    stateTitle: "Wireless resyncing"
                )
                return
            }

            wirelessConnectionState = "Connection failed"
            lastError = error?.localizedDescription
            scheduleWirelessReconnect(after: nextWirelessReconnectDelay())
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            guard isCurrentPeripheral(peripheral) else { return }

            self.peripheral = nil
            wirelessConnectionState = "Idle"
            commandCharacteristic = nil
            stateCharacteristic = nil
            pairingCharacteristic = nil
            controlCharacteristic = nil
            isWirelessStateNotificationEnabled = false
        wirelessControlNonceRecoveryTask?.cancel()
        wirelessControlNonceRecoveryTask = nil
        stopSecureLinkWatchdog()
        invalidatePreparedFastDoorCommandPayloads(clearNonce: true)
        wirelessPairingState = "Unknown"
            if isFirmwareUpdateRunning {
                wirelessConnectionState = "Updating firmware"
                return
            }
            if Self.isBluetoothEncryptionError(error) {
                lastError = nil
                if central.state == .poweredOn && canUseWirelessFallback {
                    scheduleWirelessReconnect(
                        after: Self.wirelessEncryptionRecoveryDelay,
                        stateTitle: "Wireless resyncing"
                    )
                }
                return
            }
            lastError = error?.localizedDescription
            if central.state == .poweredOn && canUseWirelessFallback {
                scheduleWirelessReconnect(after: nextWirelessReconnectDelay())
            }
        }
    }
}

extension DoorAdminStore: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            guard isCurrentPeripheral(peripheral) else { return }

            if let error {
                wirelessConnectionState = "Service failed"
                lastError = error.localizedDescription
                central?.cancelPeripheralConnection(peripheral)
                scheduleWirelessReconnect(after: nextWirelessReconnectDelay())
                return
            }

            let doorServices = peripheral.services?.filter { $0.uuid == serviceUUID } ?? []
            guard !doorServices.isEmpty else {
                wirelessConnectionState = "Service missing"
                lastError = "Door service not found over Bluetooth."
                central?.cancelPeripheralConnection(peripheral)
                scheduleWirelessReconnect(after: nextWirelessReconnectDelay())
                return
            }

            recordRuntimeTelemetry("services_discovered")
            doorServices.forEach { peripheral.discoverCharacteristics([commandUUID, stateUUID, pairingUUID, controlUUID], for: $0) }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        Task { @MainActor in
            guard isCurrentPeripheral(peripheral) else { return }

            if let error {
                wirelessConnectionState = "Characteristics failed"
                lastError = error.localizedDescription
                central?.cancelPeripheralConnection(peripheral)
                scheduleWirelessReconnect(after: nextWirelessReconnectDelay())
                return
            }

            for characteristic in service.characteristics ?? [] {
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

            if commandCharacteristic != nil && stateCharacteristic != nil && pairingCharacteristic != nil && controlCharacteristic != nil {
                wirelessKnownPeripheralFallbackTask?.cancel()
                wirelessKnownPeripheralFallbackTask = nil
                markWirelessConnectionObserved()
                wirelessConnectionState = hasTrustedMacController ? "Ready" : "USB-C trust needed"
                wirelessReconnectAttempt = 0
                message = hasTrustedMacController ? "Wireless ready" : "Connect USB-C to trust this Mac"
                firmwareLog.info("Door GATT ready trusted=\(self.hasTrustedMacController, privacy: .public) pendingFirmware=\(self.pendingFirmwareUpdatePackageURL != nil, privacy: .public)")
                recordRuntimeTelemetry("gatt_ready")
                readStateIfPossible()
                enableWirelessControlNotificationsIfPossible(on: peripheral)
                guard hasTrustedMacController else {
                    scheduleWirelessIdleDisconnect(after: 0.5)
                    return
                }
                await applyPendingAutoLockSeconds()
                await applyPendingLockName()
                await applyPendingServoAngles()
                sendQueuedWirelessCommand()
                startSecureLinkWatchdogIfNeeded()
                scheduleWirelessIdleDisconnect()
            } else if hasPendingDoorCharacteristicDiscovery(on: peripheral) {
                wirelessConnectionState = "Discovering"
                scheduleKnownPeripheralDiscoveryRetry()
            } else {
                wirelessConnectionState = "Incomplete"
                lastError = "Required Bluetooth characteristics were not found."
                central?.cancelPeripheralConnection(peripheral)
                scheduleWirelessReconnect(after: nextWirelessReconnectDelay())
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor in
            guard isCurrentPeripheral(peripheral) else { return }

            if characteristic.uuid == stateUUID {
                isWirelessStateNotificationEnabled = error == nil && characteristic.isNotifying
                if isWirelessStateNotificationEnabled {
                    recordRuntimeTelemetry("state_notify_enabled")
                    enableWirelessControlNotificationsIfPossible(on: peripheral)
                    scheduleWirelessStateSnapshotFallbackRead()
                } else if let error {
                    lastError = error.localizedDescription
                }
                return
            }

            if characteristic.uuid == controlUUID {
                if error == nil && characteristic.isNotifying {
                    firmwareLog.info("Control notifications enabled pendingFirmware=\(self.pendingFirmwareUpdatePackageURL != nil, privacy: .public)")
                    recordRuntimeTelemetry("control_notify_enabled")
                    if pendingWirelessCommandText != nil, !isWirelessDoorCommandReady {
                        message = "Preparing secure control"
                    }
                    scheduleWirelessControlNonceRecoveryIfNeeded(after: 0.06)
                    startSecureLinkWatchdogIfNeeded()
                    scheduleWirelessStateSnapshotFallbackRead()
                } else if let error {
                    lastError = error.localizedDescription
                }
                return
            }

            if let error {
                lastError = error.localizedDescription
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor in
            guard isCurrentPeripheral(peripheral) else { return }

            if let error {
                lastError = error.localizedDescription
                return
            }

            guard let data = characteristic.value else { return }
            let newState = String(data: data, encoding: .utf8) ?? "unknown"
            if characteristic.uuid == controlUUID {
                wirelessControlUpdateGeneration += 1
                wirelessControlNonceRecoveryTask?.cancel()
                wirelessControlNonceRecoveryTask = nil

                if let nonce = Self.fastCommandNonce(from: newState) {
                    applyFastCommandNonce(nonce)
                    updateWirelessPairingState(from: "paired")
                    return
                }

                if let rejectReason = Self.fastCommandRejectReason(from: newState) {
                    handleFastCommandReject(reason: rejectReason)
                    updateWirelessPairingState(from: rejectReason == "unpaired" ? "unpaired" : "paired")
                    return
                }

                if let connections = Self.connectedDevices(from: newState) {
                    var nextStatus = status
                    nextStatus.connectedCount = connections.count
                    nextStatus.maxConnections = connections.max
                    nextStatus.connectedDevices = connections.devices
                    status = statusIncludingLocalUSBConnection(nextStatus)
                    saveCachedStatus(status)
                    if wirelessPairingState == "Unknown", isWirelessReady, status.pairedCount > 0 {
                        updateWirelessPairingState(from: "paired")
                    }
                    return
                }

                return
            }

            guard characteristic.uuid == stateUUID else { return }
            wirelessStateUpdateGeneration += 1
            wirelessStateSnapshotFallbackTask?.cancel()
            wirelessStateSnapshotFallbackTask = nil
            applyWirelessState(newState)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor in
            guard isCurrentPeripheral(peripheral) else { return }

            let commandWriteIntent: WirelessCommandWriteIntent? = {
                guard characteristic.uuid == commandUUID, !pendingWirelessWriteIntents.isEmpty else {
                    return nil
                }
                return pendingWirelessWriteIntents.removeFirst()
            }()

            if let error {
                let isEncryptionError = Self.isBluetoothEncryptionError(error)
                lastError = isEncryptionError ? nil : error.localizedDescription
                if case .firmwareUpdate = commandWriteIntent {
                    firmwareLog.error("OTA DFU entry write failed: \(error.localizedDescription, privacy: .public)")
                }
                if case .autoLockTimeout(let seconds) = commandWriteIntent,
                   inFlightAutoLockSeconds == seconds {
                    inFlightAutoLockSeconds = nil
                    if pendingAutoLockSeconds == nil {
                        clearLocalSettingApply("timeout")
                        autoLockStatus = "Not set"
                    }
                }
                if case .lockName(let name) = commandWriteIntent,
                   inFlightLockName == name {
                    inFlightLockName = nil
                    pendingLockName = name
                    lockNameStatus = "Not set"
                }
                if case .servoAngles(let angles) = commandWriteIntent,
                   inFlightServoAngles == angles {
                    inFlightServoAngles = nil
                    pendingServoAngles = angles
                    clearLocalSettingApply("servo_angles")
                    servoAnglesStatus = "Not set"
                }
                if case .firmwareUpdate = commandWriteIntent {
                    pendingFirmwareUpdatePackageURL = nil
                    firmwareUpdateEntryCommandSent = false
                    firmwareUpdateStatus = "Firmware update request failed"
                    firmwareUpdateProgress = nil
                    isFirmwareUpdateRunning = false
                }
                if characteristic.uuid == pairingUUID {
                    wirelessPairingState = "Pairing locked"
                }
                if isEncryptionError {
                    scheduleWirelessReconnect(
                        after: Self.wirelessEncryptionRecoveryDelay,
                        stateTitle: "Wireless resyncing"
                    )
                } else {
                    scheduleWirelessIdleDisconnect(after: 0.5)
                }
                return
            }

            if characteristic.uuid == pairingUUID {
                if !isWirelessStateNotificationEnabled {
                    readStateIfPossible()
                }
            } else if characteristic.uuid == commandUUID {
                if case .lockName(let name) = commandWriteIntent,
                   inFlightLockName == name {
                    lockNameStatus = "Setting..."
                }
                if case .servoAngles(let angles) = commandWriteIntent,
                   inFlightServoAngles == angles {
                    servoAnglesStatus = "Setting..."
                }
                if case .firmwareUpdate = commandWriteIntent {
                    firmwareLog.info("OTA DFU entry write acknowledged; waiting for controller update mode")
                    firmwareUpdateStatus = "Waiting for controller update mode"
                    return
                }
                if !isWirelessStateNotificationEnabled {
                    readStateIfPossible()
                }
                scheduleWirelessIdleDisconnect()
            }
        }
    }
}
