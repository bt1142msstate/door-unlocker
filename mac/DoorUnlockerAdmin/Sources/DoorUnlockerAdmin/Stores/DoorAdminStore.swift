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
    }

    static let minimumAutoLockSeconds = 5
    static let maximumAutoLockSeconds = 120

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
    @Published private(set) var logLines: [String] = []
    @Published var lastError: String?

    private var connection: SerialPortConnection?
    private let serviceUUID = CBUUID(string: "7A5A1000-2B8D-4C3E-94E7-0B3C0DDAAF10")
    private let commandUUID = CBUUID(string: "7A5A1001-2B8D-4C3E-94E7-0B3C0DDAAF10")
    private let stateUUID = CBUUID(string: "7A5A1002-2B8D-4C3E-94E7-0B3C0DDAAF10")
    private let pairingUUID = CBUUID(string: "7A5A1003-2B8D-4C3E-94E7-0B3C0DDAAF10")
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var commandCharacteristic: CBCharacteristic?
    private var stateCharacteristic: CBCharacteristic?
    private var pairingCharacteristic: CBCharacteristic?
    private let serialGate = SerialTransactionGate()
    private var syncTask: Task<Void, Never>?
    private var autoLockApplyTask: Task<Void, Never>?
    private var pendingAutoLockSeconds: Int?
    private var isSilentStatusSyncInFlight = false
    private var isUSBConnectInFlight = false
    private var hasConfirmedExpiredAutoLockDeadline = false
    private var lastUSBStatusSyncAt: Date?
    private var lastUSBDiscoveryAt: Date?
    private var didTrustMacDuringUSBSession = false

    var selectedPort: SerialPortCandidate? {
        ports.first { $0.id == selectedPortID }
    }

    var selectedDevice: PairedDevice? {
        pairedDevices.first { $0.id == selectedDeviceID }
    }

    var autoLockRange: ClosedRange<Int> {
        Self.minimumAutoLockSeconds ... Self.maximumAutoLockSeconds
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

    var isWirelessReady: Bool {
        peripheral?.state == .connected && commandCharacteristic != nil && stateCharacteristic != nil
    }

    var canSendDoorCommand: Bool {
        isWirelessReady || isConnected
    }

    var primaryConnectionTitle: String {
        if isConnected && isWirelessReady {
            return "USB + Wireless"
        }
        if isWirelessReady {
            return "Wireless"
        }
        if isConnected {
            return "USB"
        }
        return "Disconnected"
    }

    override init() {
        super.init()
        refreshPorts()
        central = CBCentralManager(delegate: self, queue: .main)
        startStateSyncLoop()
    }

    deinit {
        syncTask?.cancel()
        autoLockApplyTask?.cancel()
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

        lastError = nil
        commandCharacteristic = nil
        stateCharacteristic = nil
        pairingCharacteristic = nil
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

        let deviceName = name
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !deviceName.isEmpty else {
            lastError = "Enter a device name."
            return
        }

        sendStatusCommand("app rename \(selectedDevice.slot) \(deviceName)", label: "Rename Device", timeout: 4)
    }

    func updateAutoLockSeconds(_ seconds: Int) {
        let clampedSeconds = min(max(seconds, Self.minimumAutoLockSeconds), Self.maximumAutoLockSeconds)
        guard clampedSeconds != status.autoLockSeconds || pendingAutoLockSeconds != nil else { return }

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
            await self?.applyPendingAutoLockSeconds()
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

    private func sendDoorCommand(_ command: Command) {
        if isConnected {
            switch command {
            case .lock:
                sendStatusCommand("app lock", label: "Lock", timeout: 6)
            case .unlock:
                sendStatusCommand("app unlock", label: "Unlock", timeout: 6)
            }
        } else if isWirelessReady {
            sendWirelessCommandText(command.rawValue, predictedDoorCommand: command)
        }
    }

    private func sendWirelessCommandText(_ commandText: String, predictedDoorCommand: Command? = nil) {
        guard let peripheral, let commandCharacteristic else {
            lastError = "Not connected wirelessly."
            return
        }

        do {
            let payload = try DoorCommandAuthenticator.payload(for: commandText)
            let writeType: CBCharacteristicWriteType = commandCharacteristic.properties.contains(.write) ? .withResponse : .withoutResponse
            guard payload.count <= peripheral.maximumWriteValueLength(for: writeType) else {
                lastError = "Secure command is too large for this Bluetooth connection."
                return
            }

            lastError = nil
            if let predictedDoorCommand {
                let predictedState = predictedDoorCommand == .unlock ? "unlocking" : "locking"
                var nextStatus = status
                nextStatus.bleState = predictedState
                nextStatus.isUnlocked = predictedDoorCommand == .unlock
                nextStatus.autoLockRemainingSeconds = nil
                nextStatus.autoLockDeadline = nil
                status = nextStatus
                hasConfirmedExpiredAutoLockDeadline = false
                message = predictedDoorCommand == .unlock ? "Unlocking door" : "Locking door"
            }
            peripheral.writeValue(payload, for: commandCharacteristic, type: writeType)
        } catch {
            lastError = error.localizedDescription
        }
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
            lastUSBDiscoveryAt = nil
            didTrustMacDuringUSBSession = false
            message = "Connecting to controller"

            try await Task.sleep(nanoseconds: 1_200_000_000)
            try await loadControllerState()
            try await trustThisMacOverUSBIfNeeded()
            await applyPendingAutoLockSeconds()
            if central?.state == .poweredOn && !isWirelessSessionActive {
                scanBluetooth()
            }
        }
    }

    private func autoConnectUSBIfAvailable() {
        guard selectedPort != nil,
              !isConnected,
              !isBusy,
              !isUSBConnectInFlight else { return }

        Task { await connectToSelectedPort() }
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
            didTrustMacDuringUSBSession = true
            message = "USB-C ready"
        }
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

    private func loadPairedDevices() async throws {
        let pairLines = try await transact("app pairs", until: ["APP_PAIRS_END"], timeout: 4)
        appendLog(pairLines)
        pairedDevices = DoorSerialParser.parsePairs(from: pairLines)

        if let selectedDeviceID, pairedDevices.contains(where: { $0.id == selectedDeviceID }) {
            return
        }

        selectedDeviceID = pairedDevices.first?.id
    }

    private func applyPendingAutoLockSeconds() async {
        guard let seconds = pendingAutoLockSeconds else { return }

        if isBusy {
            schedulePendingAutoLockRetry()
            return
        }

        if isConnected {
            pendingAutoLockSeconds = nil
            autoLockStatus = "Setting..."
            sendStatusCommand("app timeout \(seconds)", label: "Auto-lock", timeout: 4)
            return
        }

        if isWirelessReady {
            pendingAutoLockSeconds = nil
            autoLockStatus = "Setting..."
            sendWirelessCommandText("SET_TIMEOUT:\(seconds)")
            return
        }

        autoLockStatus = "Waiting for controller"
    }

    private func schedulePendingAutoLockRetry() {
        autoLockApplyTask?.cancel()
        autoLockApplyTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 750_000_000)
            await self?.applyPendingAutoLockSeconds()
        }
    }

    private func applyControllerStatus(_ nextStatus: ControllerStatus) {
        if !nextStatus.isUnlocked || autoLockDeadlineChanged(from: status.autoLockDeadline, to: nextStatus.autoLockDeadline) {
            hasConfirmedExpiredAutoLockDeadline = false
        }
        if nextStatus.autoLockSeconds == pendingAutoLockSeconds {
            pendingAutoLockSeconds = nil
        }
        autoLockStatus = "Controller set to \(nextStatus.autoLockSeconds)s"
        status = nextStatus
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
            return
        }

        guard shouldConfirmExpiredAutoLock, isWirelessReady else { return }
        hasConfirmedExpiredAutoLockDeadline = true
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

        self.peripheral = peripheral
        self.peripheral?.delegate = self
        wirelessConnectionState = "Connecting"
        central.stopScan()
        central.connect(peripheral, options: nil)
    }

    private func readStateIfPossible() {
        guard let peripheral, let stateCharacteristic else { return }
        if stateCharacteristic.properties.contains(.read) {
            peripheral.readValue(for: stateCharacteristic)
        }
    }

    private func applyWirelessState(_ newState: String) {
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
                status = nextStatus
                pendingAutoLockSeconds = nil
            }
            autoLockStatus = "Controller set to \(status.autoLockSeconds)s"
            updateWirelessPairingState(from: payload.state)
            return
        }

        if payload.state == "paired" {
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
        status = nextStatus
        hasConfirmedExpiredAutoLockDeadline = false
        message = statusMessage(for: status)
        updateWirelessPairingState(from: payload.state)
    }

    private func updateWirelessPairingState(from state: String) {
        switch state {
        case "pairing_enabled":
            wirelessPairingState = "Pairing enabled"
        case "pairing_pending":
            wirelessPairingState = "Pairing pending"
        case "pairing_locked", "unpaired":
            wirelessPairingState = "Pairing locked"
        case "paired", "locked", "unlocked", "locking", "unlocking", "timeout_set":
            wirelessPairingState = "Ready"
        case "rejected":
            lastError = "Command rejected. Pair this Mac over USB-C if it is not trusted yet."
        default:
            break
        }
    }
}

extension DoorAdminStore: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            switch central.state {
            case .poweredOn:
                bluetoothState = "On"
                if !isWirelessSessionActive {
                    scanBluetooth()
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
            wirelessConnectionState = "Connection failed"
            if let error {
                lastError = error.localizedDescription
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            self.peripheral = nil
            wirelessConnectionState = "Disconnected"
            commandCharacteristic = nil
            stateCharacteristic = nil
            pairingCharacteristic = nil
            wirelessPairingState = "Unknown"
            if let error {
                lastError = error.localizedDescription
            }
            if central.state == .poweredOn {
                scanBluetooth()
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
                return
            }

            let doorServices = peripheral.services?.filter { $0.uuid == serviceUUID } ?? []
            guard !doorServices.isEmpty else {
                wirelessConnectionState = "Service missing"
                lastError = "Door service not found over Bluetooth."
                return
            }

            doorServices.forEach { peripheral.discoverCharacteristics([commandUUID, stateUUID, pairingUUID], for: $0) }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        Task { @MainActor in
            if let error {
                wirelessConnectionState = "Characteristics failed"
                lastError = error.localizedDescription
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
                }
            }

            if commandCharacteristic != nil && stateCharacteristic != nil && pairingCharacteristic != nil {
                wirelessConnectionState = "Ready"
                message = "Wireless ready"
                await applyPendingAutoLockSeconds()
            } else {
                wirelessConnectionState = "Incomplete"
                lastError = "Required Bluetooth characteristics were not found."
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor in
            if let error {
                lastError = error.localizedDescription
                return
            }

            guard characteristic.uuid == stateUUID, let data = characteristic.value else { return }
            let newState = String(data: data, encoding: .utf8) ?? "unknown"
            applyWirelessState(newState)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor in
            if let error {
                lastError = error.localizedDescription
                if characteristic.uuid == pairingUUID {
                    wirelessPairingState = "Pairing locked"
                }
                return
            }

            if characteristic.uuid == pairingUUID {
                readStateIfPossible()
            } else if characteristic.uuid == commandUUID {
                readStateIfPossible()
            }
        }
    }
}
