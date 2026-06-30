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
final class DoorAdminStore: ObservableObject {
    @Published var ports: [SerialPortCandidate] = []
    @Published var selectedPortID: String?
    @Published private(set) var isConnected = false
    @Published private(set) var isBusy = false
    @Published private(set) var status = ControllerStatus.disconnected
    @Published private(set) var pairedDevices: [PairedDevice] = []
    @Published var selectedDeviceID: PairedDevice.ID?
    @Published var approvalCode = ""
    @Published private(set) var message = "Disconnected"
    @Published private(set) var logLines: [String] = []
    @Published var lastError: String?

    private var connection: SerialPortConnection?

    var selectedPort: SerialPortCandidate? {
        ports.first { $0.id == selectedPortID }
    }

    var selectedDevice: PairedDevice? {
        pairedDevices.first { $0.id == selectedDeviceID }
    }

    init() {
        refreshPorts()
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
        sendStatusCommand("app lock", label: "Lock", timeout: 6)
    }

    func unlock() {
        sendStatusCommand("app unlock", label: "Unlock", timeout: 6)
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
}
