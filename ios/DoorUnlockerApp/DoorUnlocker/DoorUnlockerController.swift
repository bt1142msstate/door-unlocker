import CoreBluetooth
import Foundation
import WidgetKit

@MainActor
final class DoorUnlockerController: NSObject, ObservableObject {
    enum Command: String {
        case unlock = "UNLOCK"
        case lock = "LOCK"
    }

    @Published private(set) var bluetoothState = "Starting"
    @Published private(set) var connectionState = "Disconnected"
    @Published private(set) var deviceName = "DoorUnlocker-XIAO"
    @Published private(set) var servoState = "unknown"
    @Published var lastError: String?

    private let serviceUUID = CBUUID(string: "4F6B8D90-7E44-4D5D-9C4E-51F0C78B6A01")
    private let commandUUID = CBUUID(string: "4F6B8D91-7E44-4D5D-9C4E-51F0C78B6A01")
    private let stateUUID = CBUUID(string: "4F6B8D92-7E44-4D5D-9C4E-51F0C78B6A01")

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var commandCharacteristic: CBCharacteristic?
    private var stateCharacteristic: CBCharacteristic?
    private var reconnectTimer: Timer?
    private var pendingSystemCommand: DoorSystemCommand?

    var isReady: Bool {
        commandCharacteristic != nil && peripheral?.state == .connected
    }

    var isUnlocked: Bool {
        servoState == "unlocked" || servoState == "unlocking"
    }

    var isChangingState: Bool {
        servoState == "locking" || servoState == "unlocking"
    }

    private var hasKnownLockState: Bool {
        servoState == "locked" || servoState == "unlocked" || servoState == "locking" || servoState == "unlocking"
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
        default:
            return isReady ? "Ready" : connectionState
        }
    }

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
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
            if let stateCharacteristic {
                peripheral.readValue(for: stateCharacteristic)
            }
            return
        }

        commandCharacteristic = nil
        stateCharacteristic = nil
        startScan()
    }

    func toggleLock() {
        send(isUnlocked ? .lock : .unlock)
    }

    func performPendingSystemCommand() {
        guard let systemCommand = DoorCommandStore.takePendingCommand() else { return }
        runSystemCommand(systemCommand)
    }

    func send(_ command: Command) {
        guard let peripheral, let commandCharacteristic else {
            lastError = "Not connected"
            return
        }

        let data = DoorCommandAuthenticator.payload(for: command)
        let writeType: CBCharacteristicWriteType = commandCharacteristic.properties.contains(.write) ? .withResponse : .withoutResponse
        guard data.count <= peripheral.maximumWriteValueLength(for: writeType) else {
            lastError = "Secure command is too large for this BLE connection"
            return
        }

        peripheral.writeValue(data, for: commandCharacteristic, type: writeType)
        servoState = command == .unlock ? "unlocking" : "locking"
        publishWidgetState(servoState)
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
                if let stateCharacteristic {
                    peripheral?.readValue(for: stateCharacteristic)
                }
                return
            }

            toggleLock()
        }
    }

    private func startScan() {
        guard central?.state == .poweredOn else { return }

        central?.stopScan()
        connectionState = "Scanning"
        central?.scanForPeripherals(withServices: [serviceUUID], options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: true
        ])
        scheduleReconnectCheck(after: 5)
    }

    private func connect(to peripheral: CBPeripheral) {
        guard let central else { return }

        if peripheral.state == .connected {
            self.peripheral = peripheral
            self.peripheral?.delegate = self
            connectionState = commandCharacteristic == nil ? "Discovering" : "Ready"
            peripheral.discoverServices([serviceUUID])
            return
        }

        guard peripheral.state != .connecting else {
            connectionState = "Connecting"
            scheduleReconnectCheck(after: 5)
            return
        }

        self.peripheral = peripheral
        self.peripheral?.delegate = self
        connectionState = "Connecting"
        central.stopScan()
        central.connect(peripheral, options: nil)
        scheduleReconnectCheck(after: 6)
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
        guard !isReady, central?.state == .poweredOn else { return }

        if let peripheral, peripheral.state == .connecting {
            central?.cancelPeripheralConnection(peripheral)
        }

        commandCharacteristic = nil
        stateCharacteristic = nil
        startScan()
    }

    private func publishWidgetState(_ state: String) {
        DoorStatusStore.save(state: state)
        WidgetCenter.shared.reloadTimelines(ofKind: "DoorUnlockerWidget")
    }
}

extension DoorUnlockerController: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            switch central.state {
            case .poweredOn:
                bluetoothState = "On"
                scan()
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
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        Task { @MainActor in
            let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
            deviceName = peripheral.name ?? localName ?? "DoorUnlocker-XIAO"
            connect(to: peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            reconnectTimer?.invalidate()
            connectionState = "Discovering"
            lastError = nil
            peripheral.delegate = self
            peripheral.discoverServices([serviceUUID])
            scheduleReconnectCheck(after: 6)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            connectionState = "Disconnected"
            lastError = error?.localizedDescription ?? "Connect failed"
            scheduleReconnectCheck(after: 1)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            connectionState = "Disconnected"
            commandCharacteristic = nil
            stateCharacteristic = nil
            if let error {
                lastError = error.localizedDescription
            }
            scheduleReconnectCheck(after: 1)
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

            doorServices.forEach { peripheral.discoverCharacteristics([commandUUID, stateUUID], for: $0) }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        Task { @MainActor in
            if let error {
                lastError = error.localizedDescription
                scheduleReconnectCheck(after: 1)
                return
            }

            for characteristic in service.characteristics ?? [] {
                if characteristic.uuid == commandUUID {
                    commandCharacteristic = characteristic
                } else if characteristic.uuid == stateUUID {
                    stateCharacteristic = characteristic
                    peripheral.setNotifyValue(true, for: characteristic)
                    peripheral.readValue(for: characteristic)
                }
            }

            if commandCharacteristic != nil {
                reconnectTimer?.invalidate()
                connectionState = "Ready"
                sendPendingSystemCommandIfReady()
            } else {
                lastError = "Command characteristic not found"
                scheduleReconnectCheck(after: 1)
            }
        }
    }

    private func sendPendingSystemCommandIfReady() {
        guard isReady, let command = pendingSystemCommand else { return }
        if command == .toggle, !hasKnownLockState {
            if let stateCharacteristic {
                peripheral?.readValue(for: stateCharacteristic)
            }
            return
        }

        pendingSystemCommand = nil
        runSystemCommand(command)
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor in
            if let error {
                lastError = error.localizedDescription
                return
            }

            guard characteristic.uuid == stateUUID, let data = characteristic.value else { return }
            let newState = String(data: data, encoding: .utf8) ?? "unknown"
            servoState = newState
            publishWidgetState(newState)
            sendPendingSystemCommandIfReady()
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor in
            if let error {
                lastError = error.localizedDescription
            }
        }
    }
}
