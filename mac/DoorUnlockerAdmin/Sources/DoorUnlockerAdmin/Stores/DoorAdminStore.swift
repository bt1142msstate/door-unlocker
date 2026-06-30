import CoreBluetooth
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

@MainActor
final class DoorAdminStore: NSObject, ObservableObject {
    enum Command: String {
        case unlock = "UNLOCK"
        case lock = "LOCK"
    }

    @Published var ports: [SerialPortCandidate] = []
    @Published var selectedPortID: String?
    @Published private(set) var isConnected = false
    @Published private(set) var bluetoothState = "Starting"
    @Published private(set) var wirelessConnectionState = "Disconnected"
    @Published private(set) var wirelessPairingState = "Unknown"
    @Published private(set) var wirelessPairingApprovalCode: String?
    @Published private(set) var isBusy = false
    @Published private(set) var status = ControllerStatus.disconnected
    @Published private(set) var pairedDevices: [PairedDevice] = []
    @Published var selectedDeviceID: PairedDevice.ID?
    @Published var approvalCode = ""
    @Published private(set) var message = "Disconnected"
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

    var selectedPort: SerialPortCandidate? {
        ports.first { $0.id == selectedPortID }
    }

    var selectedDevice: PairedDevice? {
        pairedDevices.first { $0.id == selectedDeviceID }
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
        peripheral?.state == .connected && commandCharacteristic != nil
    }

    var isWirelessPairingReady: Bool {
        peripheral?.state == .connected && pairingCharacteristic != nil
    }

    var wirelessPrimaryActionTitle: String {
        isWirelessSessionActive ? "Disconnect" : "Connect"
    }

    var canSendDoorCommand: Bool {
        isWirelessReady || isConnected
    }

    var primaryConnectionTitle: String {
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
    }

    func refreshPorts() {
        ports = SerialPortDiscovery.discover()
        if selectedPortID == nil || !ports.contains(where: { $0.id == selectedPortID }) {
            selectedPortID = ports.first?.id
        }
    }

    func connect() {
        guard !isBusy else { return }
        Task { await connectToSelectedPort() }
    }

    func disconnect() {
        connection?.close()
        connection = nil
        isConnected = false
        status = .disconnected
        pairedDevices = []
        selectedDeviceID = nil
        message = "Disconnected"
        appendLog(["Disconnected"])
    }

    func scanBluetooth() {
        guard central?.state == .poweredOn else {
            wirelessConnectionState = "Bluetooth off"
            return
        }

        lastError = nil
        commandCharacteristic = nil
        stateCharacteristic = nil
        pairingCharacteristic = nil
        wirelessPairingState = "Unknown"
        wirelessPairingApprovalCode = nil
        wirelessConnectionState = "Scanning"
        central?.stopScan()
        central?.scanForPeripherals(withServices: [serviceUUID], options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: true
        ])
    }

    func disconnectBluetooth() {
        if let peripheral {
            central?.cancelPeripheralConnection(peripheral)
        }
        central?.stopScan()
        peripheral = nil
        commandCharacteristic = nil
        stateCharacteristic = nil
        pairingCharacteristic = nil
        wirelessPairingState = "Unknown"
        wirelessPairingApprovalCode = nil
        wirelessConnectionState = "Disconnected"
    }

    func toggleWirelessConnection() {
        isWirelessSessionActive ? disconnectBluetooth() : scanBluetooth()
    }

    func refreshAll() {
        guard !isBusy else { return }
        Task { await run("Refresh") { try await loadControllerState() } }
    }

    func enablePairingMode() {
        sendStatusCommand("app pair on", label: "Enable Pairing", timeout: 4)
    }

    func disablePairingMode() {
        sendStatusCommand("app pair off", label: "Disable Pairing", timeout: 4)
    }

    func approvePairing() {
        let code = approvalCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else {
            lastError = "Enter the approval code shown on the iPhone."
            return
        }

        sendStatusCommand("app approve \(code)", label: "Approve Pairing", timeout: 5) { [weak self] in
            self?.approvalCode = ""
        }
    }

    func rejectPairing() {
        sendStatusCommand("app reject", label: "Reject Pairing", timeout: 4)
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

    func lock() {
        sendDoorCommand(.lock)
    }

    func unlock() {
        sendDoorCommand(.unlock)
    }

    func toggleLock() {
        status.isUnlocked ? lock() : unlock()
    }

    func pairThisMacWireless() {
        guard let peripheral, let pairingCharacteristic else {
            lastError = "Connect wirelessly before pairing this Mac."
            return
        }

        do {
            let deviceName = Host.current().localizedName ?? "Mac"
            let payload = try DoorCommandAuthenticator.pairingPayload(deviceName: deviceName)
            let approvalCode = try DoorCommandAuthenticator.pairingFingerprint()
            guard payload.count <= peripheral.maximumWriteValueLength(for: .withResponse) else {
                lastError = "Pairing key is too large for this Bluetooth connection."
                return
            }

            lastError = nil
            wirelessPairingApprovalCode = approvalCode
            wirelessPairingState = "Pairing"
            peripheral.writeValue(payload, for: pairingCharacteristic, type: .withResponse)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func sendDoorCommand(_ command: Command) {
        if isWirelessReady {
            sendWireless(command)
            return
        }

        switch command {
        case .lock:
            sendStatusCommand("app lock", label: "Lock", timeout: 6)
        case .unlock:
            sendStatusCommand("app unlock", label: "Unlock", timeout: 6)
        }
    }

    private func sendWireless(_ command: Command) {
        guard let peripheral, let commandCharacteristic else {
            lastError = "Not connected wirelessly."
            return
        }

        do {
            let payload = try DoorCommandAuthenticator.payload(for: command.rawValue)
            let writeType: CBCharacteristicWriteType = commandCharacteristic.properties.contains(.write) ? .withResponse : .withoutResponse
            guard payload.count <= peripheral.maximumWriteValueLength(for: writeType) else {
                lastError = "Secure command is too large for this Bluetooth connection."
                return
            }

            lastError = nil
            let predictedState = command == .unlock ? "unlocking" : "locking"
            status.bleState = predictedState
            status.isUnlocked = command == .unlock
            message = "Sent over Bluetooth"
            peripheral.writeValue(payload, for: commandCharacteristic, type: writeType)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func connectToSelectedPort() async {
        await run("Connect") {
            guard let selectedPort else { throw DoorAdminError.noPortSelected }

            connection?.close()
            connection = try SerialPortConnection(path: selectedPort.path)
            isConnected = true
            message = "Waiting for controller"

            try await Task.sleep(nanoseconds: 1_200_000_000)
            try await loadControllerState()
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
                status = DoorSerialParser.parseStatus(from: lines)
                message = DoorSerialParser.responseSummary(from: lines) ?? label
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
            message = "Error"
            appendLog(["ERROR \(error.localizedDescription)"])
        }
    }

    private func loadControllerState() async throws {
        let statusLines = try await transact("app status", until: ["APP_STATUS_END"], timeout: 4)
        appendLog(statusLines)
        status = DoorSerialParser.parseStatus(from: statusLines)
        message = DoorSerialParser.responseSummary(from: statusLines) ?? "Connected"
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

    private func transact(_ command: String, until markers: Set<String>, timeout: TimeInterval) async throws -> [String] {
        guard let connection else { throw DoorAdminError.notConnected }
        return try await Task.detached(priority: .userInitiated) {
            try connection.transact(command, until: markers, timeout: timeout)
        }.value
    }

    private func appendLog(_ lines: [String]) {
        logLines.append(contentsOf: lines)
        if logLines.count > 120 {
            logLines.removeFirst(logLines.count - 120)
        }
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
        status.bleState = newState
        status.isUnlocked = newState == "unlocked" || newState == "unlocking"
        message = "Wireless \(status.stateTitle)"
        updateWirelessPairingState(from: newState)
    }

    private func updateWirelessPairingState(from state: String) {
        switch state {
        case "pairing_enabled":
            wirelessPairingState = "Pairing enabled"
            wirelessPairingApprovalCode = nil
        case "pairing_pending":
            wirelessPairingState = "Pairing pending"
            if wirelessPairingApprovalCode == nil {
                wirelessPairingApprovalCode = try? DoorCommandAuthenticator.pairingFingerprint()
            }
        case "pairing_locked", "unpaired":
            wirelessPairingState = "Pairing locked"
            wirelessPairingApprovalCode = nil
        case "paired", "locked", "unlocked", "locking", "unlocking", "timeout_set":
            wirelessPairingState = "Ready"
            if state == "paired" {
                wirelessPairingApprovalCode = nil
            }
        case "rejected":
            lastError = "Wireless command was rejected. Pair this Mac over USB if it is not trusted yet."
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
            wirelessPairingApprovalCode = nil
            if let error {
                lastError = error.localizedDescription
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

            if commandCharacteristic != nil && pairingCharacteristic != nil {
                wirelessConnectionState = "Ready"
                message = "Wireless ready"
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
