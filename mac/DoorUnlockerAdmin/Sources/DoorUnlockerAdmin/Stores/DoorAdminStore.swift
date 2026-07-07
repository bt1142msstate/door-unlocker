import CoreBluetooth
import DoorUnlockerCore
import Foundation

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
    enum Command: String {
        case unlock = "UNLOCK"
        case lock = "LOCK"

        var commandText: String {
            rawValue
        }
    }

    private enum WirelessCommandWriteIntent {
        case doorCommand
        case autoLockTimeout(Int)
        case lockName(String)
        case servoAngles(ServoAngles)
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
    private static let trustedMacControllerKey = "DoorUnlockerAdminTrustedMacController"
    private static let localSigningPublicKeyKey = "DoorUnlockerAdminLocalSigningPublicKey"
    private static let pairedDevicesSyncInterval: TimeInterval = 5
    private static let wirelessStatePollInterval: TimeInterval = 10
    private static let wirelessReconnectDelays: [TimeInterval] = [0.8, 1.5, 3, 5, 8]
    private static let wirelessEncryptionRecoveryDelay: TimeInterval = 15

    @Published private(set) var lockName = DoorAdminStore.loadLockName()
    @Published private(set) var lockNameStatus = "Controller name"
    @Published var ports: [SerialPortCandidate] = []
    @Published var selectedPortID: String?
    @Published private(set) var isConnected = false
    @Published private(set) var bluetoothState = "Starting"
    @Published private(set) var wirelessConnectionState = "Disconnected"
    @Published private(set) var wirelessPairingState = "Unknown"
    @Published private(set) var isBusy = false
    @Published private(set) var status = ControllerStatus.disconnected
    @Published private(set) var pairedDevices: [PairedDevice] = []
    @Published var selectedDeviceID: PairedDevice.ID?
    @Published var approvalCode = ""
    @Published private(set) var message = "Disconnected"
    @Published private(set) var autoLockStatus = "Ready"
    @Published private(set) var servoAnglesStatus = "Controller set"
    @Published private(set) var logLines: [String] = []
    @Published private(set) var localSettingApplyKind: String?
    @Published private(set) var remoteSettingApplyKind: String?
    @Published private(set) var remoteSettingApplyValue: String?
    @Published var lastError: String?

    var isChangingDoorState: Bool {
        status.bleState == "locking" || status.bleState == "unlocking"
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
    private var fastCommandNonce: Data?
    private var preparedFastDoorCommandPayloads: [Command: DoorCommandAuthenticator.SignedFastCommandPayload] = [:]
    private var preparedFastDoorCommandTask: Task<Void, Never>?
    private var preparedFastDoorCommandGeneration = 0
    private var remoteSettingApplyTask: Task<Void, Never>?
    private var wirelessReconnectTask: Task<Void, Never>?
    private var wirelessIdleDisconnectTask: Task<Void, Never>?
    private var pendingWirelessWriteIntents: [WirelessCommandWriteIntent] = []
    private var wirelessReconnectAttempt = 0
    private var isWirelessStateNotificationEnabled = false

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
        isWirelessReady && !preparedFastDoorCommandPayloads.isEmpty
    }

    private var canUseWirelessFallback: Bool {
        !isConnected && !isUSBConnectInFlight && hasTrustedMacController
    }

    private var wirelessStopReason: String {
        isConnected || isUSBConnectInFlight ? "USB-C active" : "Idle"
    }

    private static func currentEpochSeconds() -> UInt64 {
        UInt64(max(0, Date().timeIntervalSince1970.rounded(.down)))
    }

    private static func appUnlockCommandText() -> String {
        let deviceName = DoorDeviceNameNormalizer.normalized(Host.current().localizedName ?? "Mac", fallback: "Mac")
        return "app unlock \(currentEpochSeconds()) \(deviceName)"
    }

    private static func appLockCommandText() -> String {
        "app lock \(currentEpochSeconds())"
    }

    var canSendDoorCommand: Bool {
        isConnected || isWirelessDoorCommandReady || (hasTrustedMacController && central?.state == .poweredOn && !isWirelessReady)
    }

    var primaryConnectionTitle: String {
        if isConnected {
            return "USB"
        }
        if isWirelessReady {
            return "Wireless"
        }
        return "Disconnected"
    }

    var stateTitle: String {
        let title = status.stateTitle
        return title == "Unknown" ? "Disconnected" : title
    }

    var controllerStatusTitle: String {
        if status.hasPendingRequest {
            return "Pairing request"
        }
        if isConnected || isWirelessReady {
            return "Controller ready"
        }
        if bluetoothState != "On" {
            return "Bluetooth \(bluetoothState)"
        }
        return wirelessConnectionState
    }

    var controllerStatusDetail: String {
        "Connection \(primaryConnectionTitle) - Connected \(status.connectedCount)/\(max(status.maxConnections, 4)) - Trusted \(status.pairedCount)/\(max(status.maxPairs, 4))"
    }

    var controllerStatusSymbol: String {
        if status.hasPendingRequest {
            return "person.badge.key.fill"
        }
        if isConnected || isWirelessReady {
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
            return "Admin commands and settings use USB-C. Wireless stays paused so the iPhone can connect."
        }
        if isWirelessReady {
            return "Wireless is connected. The controller serializes commands from multiple trusted devices."
        }
        if isWirelessGattReady {
            return "Connect USB-C once to trust this Mac for secure wireless commands."
        }
        if bluetoothState != "On" {
            return "Turn Bluetooth on to use wireless control."
        }
        return "USB-C connects automatically when plugged in. Wireless connects on demand so the iPhone stays responsive."
    }

    override init() {
        super.init()
        reconcileLocalSigningIdentityTrust()
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleLocalCommandNotification(_:)),
            name: DoorLocalCommandBridge.notificationName,
            object: DoorLocalCommandBridge.sender
        )
        refreshPorts()
        central = CBCentralManager(delegate: self, queue: .main)
        startStateSyncLoop()
    }

    private func reconcileLocalSigningIdentityTrust() {
        guard let publicKey = try? DoorCommandAuthenticator.publicKeyX963Representation() else {
            return
        }

        let encodedPublicKey = publicKey.base64EncodedString()
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
        autoLockApplyTask?.cancel()
        lockNameApplyTask?.cancel()
        servoAnglesApplyTask?.cancel()
        wirelessReconnectTask?.cancel()
        wirelessIdleDisconnectTask?.cancel()
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
        guard central?.state == .poweredOn else {
            wirelessConnectionState = "Bluetooth off"
            return
        }
        guard canUseWirelessFallback else {
            stopWirelessSession(reason: wirelessStopReason)
            return
        }
        if peripheral?.state == .connected, isWirelessGattReady {
            return
        }
        if peripheral?.state == .connecting {
            return
        }

        wirelessReconnectTask?.cancel()
        wirelessReconnectTask = nil
        lastError = nil
        commandCharacteristic = nil
        stateCharacteristic = nil
        pairingCharacteristic = nil
        controlCharacteristic = nil
        isWirelessStateNotificationEnabled = false
        invalidatePreparedFastDoorCommandPayloads(clearNonce: true)
        wirelessPairingState = "Unknown"
        hasConfirmedExpiredAutoLockDeadline = false
        wirelessConnectionState = "Scanning"
        central?.stopScan()
        central?.scanForPeripherals(withServices: [serviceUUID], options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: true
        ])
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
            try? await Task.sleep(nanoseconds: 400_000_000)
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
            try? await Task.sleep(nanoseconds: 400_000_000)
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
        default:
            break
        }
    }

    private func sendDoorCommand(_ command: Command) {
        if isConnected {
            applyPredictedDoorCommand(command)
            switch command {
            case .lock:
                sendStatusCommand(Self.appLockCommandText(), label: "Lock", timeout: 6)
            case .unlock:
                sendStatusCommand(Self.appUnlockCommandText(), label: "Unlock", timeout: 6)
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
        wirelessConnectionState = "Connecting on demand"

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
        if sendWirelessCommandText(commandText, predictedDoorCommand: predictedCommand, intent: intent) {
            pendingWirelessCommandText = nil
            pendingWirelessPredictedCommand = nil
            pendingWirelessCommandIntent = nil
        }
    }

    @discardableResult
    private func sendWirelessCommandText(
        _ commandText: String,
        predictedDoorCommand: Command? = nil,
        intent: WirelessCommandWriteIntent = .generic
    ) -> Bool {
        guard let peripheral, let commandCharacteristic else {
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
            lastError = "Bluetooth is not ready yet."
            return false
        }

        if case .doorCommand = intent {
            guard let predictedDoorCommand else {
                lastError = "Door command is missing."
                return false
            }
            guard let preparedFastPayload = preparedFastDoorCommandPayloads[predictedDoorCommand],
                  let writeType = preferredFastDoorCommandWriteType(
                    for: preparedFastPayload.data,
                    peripheral: peripheral,
                    characteristic: commandCharacteristic
                  ) else {
                lastError = preparedFastDoorCommandTask == nil && fastCommandNonce == nil
                    ? "Waiting for controller secure nonce."
                    : "Preparing secure \(predictedDoorCommand == .unlock ? "unlock" : "lock")."
                return false
            }

            invalidatePreparedFastDoorCommandPayloads(clearNonce: true)
            lastError = nil
            applyPredictedDoorCommand(predictedDoorCommand)
            peripheral.writeValue(preparedFastPayload.data, for: commandCharacteristic, type: writeType)
            scheduleWirelessIdleDisconnect()
            return true
        }

        guard let nonce = fastCommandNonce else {
            lastError = "Waiting for controller secure nonce."
            return false
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
            if writeType == .withoutResponse {
                scheduleWirelessIdleDisconnect()
            }
            return true
        } catch {
            lastError = error.localizedDescription
            return false
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

    private func connectToSelectedPort() async {
        guard !isUSBConnectInFlight else { return }

        isUSBConnectInFlight = true
        defer { isUSBConnectInFlight = false }

        await run("Connecting") {
            guard let selectedPort else { throw DoorAdminError.noPortSelected }

            connection?.close()
            connection = try SerialPortConnection(path: selectedPort.path)
            isConnected = true
            lastUSBStatusSyncAt = nil
            lastPairedDevicesSyncAt = nil
            lastUSBDiscoveryAt = nil
            didTrustMacDuringUSBSession = false
            message = "Connecting to controller"
            stopWirelessSession(reason: "USB-C active")

            try await Task.sleep(nanoseconds: 1_200_000_000)
            try await loadControllerState()
            try await trustThisMacOverUSBIfNeeded()
            await applyPendingAutoLockSeconds()
            await applyPendingServoAngles()
        }
    }

    private func autoConnectUSBIfAvailable() {
        guard selectedPort != nil,
              !isConnected,
              !isBusy,
              !isUSBConnectInFlight else { return }

        Task { await connectToSelectedPort() }
    }

    private func markUSBDisconnected(reason: String) {
        connection?.close()
        connection = nil
        isConnected = false
        isUSBConnectInFlight = false
        lastUSBStatusSyncAt = nil
        didTrustMacDuringUSBSession = false
        message = reason

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

        let deviceName = Host.current().localizedName ?? "Mac"
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

    private func setTrustedMacController(_ isTrusted: Bool) {
        hasTrustedMacController = isTrusted
        UserDefaults.standard.set(isTrusted, forKey: Self.trustedMacControllerKey)
    }

    private func sendStatusCommand(
        _ command: String,
        label: String,
        timeout: TimeInterval,
        afterSuccess: (() -> Void)? = nil
    ) {
        guard !isBusy else { return }
        Task {
            await run(label) {
                let lines = try await transact(command, until: ["APP_STATUS_END"], timeout: timeout)
                appendLog(lines)
                applyControllerStatus(DoorSerialParser.parseStatus(from: lines))
                message = successMessage(for: label, status: status)
                try await loadPairedDevices()
                afterSuccess?()
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
            lastError = error.localizedDescription
            message = "Something went wrong"
            appendLog(["ERROR \(error.localizedDescription)"])
        }
    }

    private func loadControllerState() async throws {
        let statusLines = try await transact("app status", until: ["APP_STATUS_END"], timeout: 4)
        appendLog(statusLines)
        applyControllerStatus(DoorSerialParser.parseStatus(from: statusLines))
        message = statusMessage(for: status)
        try await loadPairedDevices()
    }

    private func loadPairedDevices(shouldLog: Bool = true) async throws {
        let pairLines = try await transact("app pairs", until: ["APP_PAIRS_END"], timeout: 4)
        if shouldLog {
            appendLog(pairLines)
        }
        pairedDevices = DoorSerialParser.parsePairs(from: pairLines)
        lastPairedDevicesSyncAt = .now

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
            sendStatusCommand("app timeout \(seconds)", label: "Auto-lock", timeout: 4)
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
            sendStatusCommand("app angles \(angles.lockAngle) \(angles.unlockAngle)", label: "Servo angles", timeout: 4)
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
        var nextStatus = nextStatus
        if let applyingKind = nextStatus.settingApplyingKind {
            applyRemoteSettingApplying(kind: applyingKind, value: nextStatus.settingApplyingValue)
            nextStatus.settingApplyingKind = nil
            nextStatus.settingApplyingValue = nil
        }
        reconcileAutoLockSeconds(in: &nextStatus)
        reconcileServoAngles(in: &nextStatus)
        applyControllerLockName(nextStatus.lockName)

        if !nextStatus.isUnlocked || autoLockDeadlineChanged(from: status.autoLockDeadline, to: nextStatus.autoLockDeadline) {
            hasConfirmedExpiredAutoLockDeadline = false
        }
        status = nextStatus
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
            sendStatusCommand("app lock name \(name)", label: "Lock name", timeout: 10)
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

        if self.peripheral?.identifier == peripheral.identifier {
            if peripheral.state == .connected {
                if !isWirelessGattReady {
                    peripheral.discoverServices([serviceUUID])
                }
                return
            }
            if peripheral.state == .connecting {
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
        invalidatePreparedFastDoorCommandPayloads(clearNonce: true)
        wirelessPairingState = "Unknown"
        lastWirelessStateSyncAt = nil
        self.peripheral = peripheral
        self.peripheral?.delegate = self
        wirelessConnectionState = "Connecting"
        central.stopScan()
        central.connect(peripheral, options: nil)
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
        central?.stopScan()
        if let peripheral, peripheral.state == .connected || peripheral.state == .connecting {
            central?.cancelPeripheralConnection(peripheral)
        }
        pendingWirelessWriteIntents = []
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

    private func readAckIfPossible() {
        guard let peripheral, let controlCharacteristic else { return }
        if controlCharacteristic.properties.contains(.read) {
            peripheral.readValue(for: controlCharacteristic)
        }
    }

    private func prepareFastDoorCommandPayloads(for nonce: Data) {
        preparedFastDoorCommandGeneration += 1
        let generation = preparedFastDoorCommandGeneration

        preparedFastDoorCommandTask?.cancel()
        preparedFastDoorCommandTask = Task { [weak self] in
            let payloads = try? await Task.detached(priority: .userInitiated) {
                try DoorCommandAuthenticator.fastCommandPayloads(nonce: nonce)
            }.value

            guard !Task.isCancelled, let payloads else { return }

            await MainActor.run {
                guard let self,
                      self.preparedFastDoorCommandGeneration == generation,
                      self.fastCommandNonce == nonce,
                      self.hasTrustedMacController else {
                    return
                }

                self.preparedFastDoorCommandPayloads = [
                    .unlock: payloads[.unlock],
                    .lock: payloads[.lock]
                ].compactMapValues { $0 }
                self.preparedFastDoorCommandTask = nil
                self.sendQueuedWirelessCommand()
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

    private func applyWirelessState(_ newState: String) {
        if let applying = Self.settingApplying(from: newState) {
            applyRemoteSettingApplying(kind: applying.kind, value: applying.value)
            updateWirelessPairingState(from: "paired")
            return
        }

        if let controllerLockName = Self.lockName(from: newState) {
            applyControllerLockName(controllerLockName)
            updateWirelessPairingState(from: "paired")
            if inFlightServoAngles == nil && pendingServoAngles == nil {
                requestControllerServoAnglesOverWirelessIfNeeded()
            }
            return
        }

        if let controllerAngles = Self.servoAngles(from: newState) {
            var nextStatus = status
            nextStatus.lockAngle = controllerAngles.lockAngle
            nextStatus.unlockAngle = controllerAngles.unlockAngle
            reconcileServoAngles(in: &nextStatus)
            status = nextStatus
            updateWirelessPairingState(from: "paired")
            requestControllerLastUnlockOverWirelessIfNeeded()
            return
        }

        if let lastUnlock = Self.lastUnlockRecord(from: newState) {
            var nextStatus = status
            nextStatus.lastUnlockAt = lastUnlock.unlockedAt
            nextStatus.lastUnlockDeviceIdentifier = lastUnlock.deviceIdentifier
            nextStatus.lastUnlockDeviceName = lastUnlock.deviceName
            status = nextStatus
            updateWirelessPairingState(from: "paired")
            return
        }

        if let connections = Self.connectedDevices(from: newState) {
            var nextStatus = status
            nextStatus.connectedCount = connections.count
            nextStatus.maxConnections = connections.max
            nextStatus.connectedDevices = connections.devices
            status = nextStatus
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
            lastError = "Controller asked for a fresh secure command."
        case "bad_signature", "unpaired":
            lastError = "Controller rejected the command."
        default:
            lastError = "Controller rejected the command."
        }

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

    @discardableResult
    private func requestControllerLockNameOverWirelessIfNeeded() -> Bool {
        guard isWirelessReady else { return false }
        return sendWirelessCommandText("GET_LOCK_NAME")
    }

    @discardableResult
    private func requestControllerServoAnglesOverWirelessIfNeeded() -> Bool {
        guard isWirelessReady else { return false }
        return sendWirelessCommandText("GET_ANGLES")
    }

    @discardableResult
    private func requestControllerLastUnlockOverWirelessIfNeeded() -> Bool {
        guard isWirelessReady else { return false }
        return sendWirelessCommandText("GET_LAST_UNLOCK")
    }
}

extension DoorAdminStore: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            switch central.state {
            case .poweredOn:
                bluetoothState = "On"
                if canUseWirelessFallback && !isWirelessSessionActive {
                    scanBluetooth()
                } else if isConnected || isUSBConnectInFlight {
                    stopWirelessSession(reason: "USB-C active")
                } else {
                    stopWirelessSession(reason: "Idle")
                }
            case .poweredOff:
                bluetoothState = "Off"
                wirelessConnectionState = "Bluetooth off"
            case .unauthorized:
                bluetoothState = "Unauthorized"
                wirelessConnectionState = "Bluetooth permission needed"
            case .unsupported:
                bluetoothState = "Unsupported"
            case .resetting:
                bluetoothState = "Resetting"
            case .unknown:
                bluetoothState = "Unknown"
            @unknown default:
                bluetoothState = "Unknown"
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
            wirelessConnectionState = "Discovering"
            peripheral.discoverServices([serviceUUID])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
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
            self.peripheral = nil
            wirelessConnectionState = "Idle"
            commandCharacteristic = nil
            stateCharacteristic = nil
            pairingCharacteristic = nil
            controlCharacteristic = nil
            isWirelessStateNotificationEnabled = false
            invalidatePreparedFastDoorCommandPayloads(clearNonce: true)
            wirelessPairingState = "Unknown"
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

            doorServices.forEach { peripheral.discoverCharacteristics([commandUUID, stateUUID, pairingUUID, controlUUID], for: $0) }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        Task { @MainActor in
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
                    if characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
                        peripheral.setNotifyValue(true, for: characteristic)
                    }
                    readStateIfPossible()
                } else if characteristic.uuid == pairingUUID {
                    pairingCharacteristic = characteristic
                } else if characteristic.uuid == controlUUID {
                    controlCharacteristic = characteristic
                    if characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
                        peripheral.setNotifyValue(true, for: characteristic)
                    }
                }
            }

            if commandCharacteristic != nil && stateCharacteristic != nil && pairingCharacteristic != nil && controlCharacteristic != nil {
                wirelessConnectionState = hasTrustedMacController ? "Ready" : "USB-C trust needed"
                wirelessReconnectAttempt = 0
                message = hasTrustedMacController ? "Wireless ready" : "Connect USB-C to trust this Mac"
                guard hasTrustedMacController else {
                    scheduleWirelessIdleDisconnect(after: 0.5)
                    return
                }
                await applyPendingAutoLockSeconds()
                await applyPendingLockName()
                await applyPendingServoAngles()
                sendQueuedWirelessCommand()
                scheduleWirelessIdleDisconnect()
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
            if characteristic.uuid == stateUUID {
                isWirelessStateNotificationEnabled = error == nil && characteristic.isNotifying
                if isWirelessStateNotificationEnabled {
                    readStateIfPossible()
                } else if let error {
                    lastError = error.localizedDescription
                }
                return
            }

            if characteristic.uuid == controlUUID {
                if error == nil && characteristic.isNotifying {
                    readAckIfPossible()
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
            if let error {
                lastError = error.localizedDescription
                return
            }

            guard let data = characteristic.value else { return }
            let newState = String(data: data, encoding: .utf8) ?? "unknown"
            if characteristic.uuid == controlUUID {
                if let nonce = Self.fastCommandNonce(from: newState) {
                    applyFastCommandNonce(nonce)
                    updateWirelessPairingState(from: "paired")
                    return
                }

                if let rejectReason = Self.fastCommandRejectReason(from: newState) {
                    handleFastCommandReject(reason: rejectReason)
                    updateWirelessPairingState(from: "paired")
                    return
                }

                return
            }

            guard characteristic.uuid == stateUUID else { return }
            applyWirelessState(newState)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor in
            let commandWriteIntent: WirelessCommandWriteIntent? = {
                guard characteristic.uuid == commandUUID, !pendingWirelessWriteIntents.isEmpty else {
                    return nil
                }
                return pendingWirelessWriteIntents.removeFirst()
            }()

            if let error {
                let isEncryptionError = Self.isBluetoothEncryptionError(error)
                lastError = isEncryptionError ? nil : error.localizedDescription
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
                if case .doorCommand = commandWriteIntent {
                    readAckIfPossible()
                }
                if case .lockName(let name) = commandWriteIntent,
                   inFlightLockName == name {
                    lockNameStatus = "Waiting for controller"
                }
                if case .servoAngles(let angles) = commandWriteIntent,
                   inFlightServoAngles == angles {
                    servoAnglesStatus = "Waiting for controller"
                }
                if !isWirelessStateNotificationEnabled {
                    readStateIfPossible()
                }
                scheduleWirelessIdleDisconnect()
            }
        }
    }
}
