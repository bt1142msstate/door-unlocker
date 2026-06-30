import CoreBluetooth
import Foundation
import ActivityKit
import LocalAuthentication
import UIKit
import WidgetKit

@MainActor
final class DoorUnlockerController: NSObject, ObservableObject {
    enum Command: String {
        case unlock = "UNLOCK"
        case lock = "LOCK"
    }

    static let defaultAutoLockSeconds = 30
    static let minimumAutoLockSeconds = 5
    static let maximumAutoLockSeconds = 120

    @Published private(set) var bluetoothState = "Starting"
    @Published private(set) var connectionState = "Disconnected"
    @Published private(set) var deviceName = "DoorUnlocker-XIAO-v2"
    @Published private(set) var servoState = "unknown"
    @Published private(set) var pairingState = "Unknown"
    @Published private(set) var pairingApprovalCode: String?
    @Published private(set) var isAuthenticatingUnlock = false
    @Published private(set) var autoLockSeconds = DoorUnlockerController.storedAutoLockSeconds()
    @Published private(set) var autoLockStatus = "Ready to set"
    @Published private(set) var autoLockRemainingSeconds: Int?
    @Published var requiresUnlockAuthentication = UserDefaults.standard.bool(forKey: DoorUnlockerController.unlockAuthenticationKey) {
        didSet {
            UserDefaults.standard.set(requiresUnlockAuthentication, forKey: Self.unlockAuthenticationKey)
        }
    }
    @Published var lastError: String?

    private static let unlockAuthenticationKey = "RequireUnlockAuthentication"
    private static let autoLockSecondsKey = "AutoLockSeconds"
    private let serviceUUID = CBUUID(string: "7A5A1000-2B8D-4C3E-94E7-0B3C0DDAAF10")
    private let commandUUID = CBUUID(string: "7A5A1001-2B8D-4C3E-94E7-0B3C0DDAAF10")
    private let stateUUID = CBUUID(string: "7A5A1002-2B8D-4C3E-94E7-0B3C0DDAAF10")
    private let pairingUUID = CBUUID(string: "7A5A1003-2B8D-4C3E-94E7-0B3C0DDAAF10")

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var commandCharacteristic: CBCharacteristic?
    private var stateCharacteristic: CBCharacteristic?
    private var pairingCharacteristic: CBCharacteristic?
    private var reconnectTimer: Timer?
    private var pendingSystemCommand: DoorSystemCommand?
    private var pendingAutoLockTimeoutSeconds: Int?
    private var queuedAutoLockTimeoutSeconds: Int?
    private var autoLockApplyTask: Task<Void, Never>?
    private var autoLockPredictionTask: Task<Void, Never>?
    private var liveActivity: Activity<DoorUnlockerActivityAttributes>?
    private var liveActivityBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var liveActivityStartTask: Task<Void, Never>?
    private var isAppActive = true
    private var pendingLiveActivityState: (state: String, deadline: Date)?

    var isConnectedToController: Bool {
        pairingCharacteristic != nil && peripheral?.state == .connected
    }

    var isPaired: Bool {
        pairingState == "Paired"
    }

    var isReady: Bool {
        commandCharacteristic != nil && peripheral?.state == .connected && isPaired
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

    var autoLockCountdownText: String? {
        guard isUnlocked, let autoLockRemainingSeconds else { return nil }
        guard autoLockRemainingSeconds > 0 else { return "Auto-locking now" }
        return "Auto-locks in \(autoLockRemainingSeconds)s"
    }

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    private static func storedAutoLockSeconds() -> Int {
        let storedValue = UserDefaults.standard.integer(forKey: autoLockSecondsKey)
        let seconds = storedValue == 0 ? defaultAutoLockSeconds : storedValue
        return clampedAutoLockSeconds(seconds)
    }

    private static func clampedAutoLockSeconds(_ seconds: Int) -> Int {
        min(max(seconds, minimumAutoLockSeconds), maximumAutoLockSeconds)
    }

    func updateAutoLockSeconds(_ seconds: Int) {
        autoLockSeconds = Self.clampedAutoLockSeconds(seconds)
        UserDefaults.standard.set(autoLockSeconds, forKey: Self.autoLockSecondsKey)
        scheduleAutoLockTimeoutApply()
    }

    private func scheduleAutoLockTimeoutApply() {
        autoLockApplyTask?.cancel()
        autoLockStatus = isReady ? "Setting..." : "Waiting for controller"

        autoLockApplyTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }

            await MainActor.run {
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

        if !writeAuthenticatedCommand(commandText) {
            pendingAutoLockTimeoutSeconds = nil
            autoLockStatus = "Not set"
        }
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
            return
        }

        commandCharacteristic = nil
        stateCharacteristic = nil
        pairingCharacteristic = nil
        pairingState = "Unknown"
        pairingApprovalCode = nil
        startScan()
    }

    func refreshStateFromController() {
        reconcilePredictedAutoLock()
        if !readStateIfPermitted() {
            scan()
        }
    }

    func setAppActive(_ active: Bool) {
        isAppActive = active

        if active {
            liveActivityStartTask?.cancel()
            liveActivityStartTask = nil
            endLiveActivityBackgroundTask()
            Task { await endLiveActivity() }
            return
        }

        guard let pendingLiveActivityState,
              pendingLiveActivityState.deadline > .now else {
            return
        }

        scheduleLiveActivityStart(
            state: pendingLiveActivityState.state,
            deadline: pendingLiveActivityState.deadline
        )
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

    private func sendAuthenticated(_ command: Command) {
        let didWrite = writeAuthenticatedCommand(command.rawValue)
        if didWrite {
            servoState = command == .unlock ? "unlocking" : "locking"
            publishWidgetState(servoState, resetAutoLockDeadline: command == .unlock)
        }
    }

    @discardableResult
    private func writeAuthenticatedCommand(_ commandText: String) -> Bool {
        guard let peripheral, let commandCharacteristic else {
            lastError = "Not connected"
            return false
        }

        guard isPaired else {
            lastError = "Pair this iPhone before sending commands"
            return false
        }

        let data: Data
        do {
            data = try DoorCommandAuthenticator.payload(for: commandText)
        } catch {
            lastError = error.localizedDescription
            return false
        }

        let writeType: CBCharacteristicWriteType = commandCharacteristic.properties.contains(.write) ? .withResponse : .withoutResponse
        guard data.count <= peripheral.maximumWriteValueLength(for: writeType) else {
            lastError = "Secure command is too large for this BLE connection"
            return false
        }

        lastError = nil
        peripheral.writeValue(data, for: commandCharacteristic, type: writeType)
        return true
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
            let publicKey = try DoorCommandAuthenticator.publicKeyForPairing()
            let approvalCode = try DoorCommandAuthenticator.pairingFingerprint()
            guard publicKey.count <= peripheral.maximumWriteValueLength(for: .withResponse) else {
                lastError = "Pairing key is too large for this BLE connection"
                return
            }

            lastError = nil
            pairingApprovalCode = approvalCode
            pairingState = "Pairing"
            peripheral.writeValue(publicKey, for: pairingCharacteristic, type: .withResponse)
        } catch {
            lastError = error.localizedDescription
        }
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
        pairingCharacteristic = nil
        pairingState = "Unknown"
        pairingApprovalCode = nil
        startScan()
    }

    private func publishWidgetState(_ state: String, updatedAt: Date = .now, resetAutoLockDeadline: Bool = false) {
        let deadline = predictedAutoLockDeadline(for: state, updatedAt: updatedAt, resetAutoLockDeadline: resetAutoLockDeadline)
        DoorStatusStore.save(state: state, updatedAt: updatedAt, autoLockDeadline: deadline)
        WidgetCenter.shared.reloadTimelines(ofKind: "DoorUnlockerWidget")
        scheduleAutoLockPrediction(deadline: deadline)
        syncLiveActivity(state: state, deadline: deadline)
    }

    private func predictedAutoLockDeadline(for state: String, updatedAt: Date, resetAutoLockDeadline: Bool) -> Date? {
        switch state {
        case "unlocking", "unlocked":
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

    private func syncLiveActivity(state: String, deadline: Date?) {
        if (state == "unlocked" || state == "unlocking"), let deadline, deadline > .now {
            pendingLiveActivityState = (state, deadline)
            guard !isAppActive else {
                Task { await endLiveActivity() }
                return
            }

            scheduleLiveActivityStart(state: state, deadline: deadline)
        } else {
            liveActivityStartTask?.cancel()
            liveActivityStartTask = nil
            pendingLiveActivityState = nil
            endLiveActivityBackgroundTask()
            Task { await endLiveActivity() }
        }
    }

    private func scheduleLiveActivityStart(state: String, deadline: Date) {
        liveActivityStartTask?.cancel()
        beginLiveActivityBackgroundTask()
        liveActivityStartTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            await self?.startLiveActivityIfAllowed(state: state, deadline: deadline)
        }
    }

    private func startLiveActivityIfAllowed(state: String, deadline: Date) async {
        guard !isAppActive, deadline > .now else {
            endLiveActivityBackgroundTask()
            return
        }

        await startOrUpdateLiveActivity(state: state, deadline: deadline)
    }

    private func startOrUpdateLiveActivity(state: String, deadline: Date) async {
        defer { endLiveActivityBackgroundTask() }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let contentState = DoorUnlockerActivityAttributes.ContentState(state: state, autoLockDeadline: deadline)
        let content = ActivityContent(
            state: contentState,
            staleDate: deadline
        )

        do {
            if let activity = liveActivity ?? Activity<DoorUnlockerActivityAttributes>.activities.first {
                liveActivity = activity
                await activity.update(content)
            } else {
                let attributes = DoorUnlockerActivityAttributes(title: "Door Unlocker")
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

    private func endLiveActivity() async {
        let activities = Activity<DoorUnlockerActivityAttributes>.activities
        guard liveActivity != nil || !activities.isEmpty else { return }

        let content = ActivityContent(
            state: DoorUnlockerActivityAttributes.ContentState(state: "locked", autoLockDeadline: .now),
            staleDate: nil
        )

        for activity in activities {
            await activity.end(content, dismissalPolicy: .immediate)
        }
        liveActivity = nil
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
            deviceName = peripheral.name ?? localName ?? "DoorUnlocker-XIAO-v2"
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
            pairingCharacteristic = nil
            pairingState = "Unknown"
            pairingApprovalCode = nil
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

            doorServices.forEach { peripheral.discoverCharacteristics([commandUUID, stateUUID, pairingUUID], for: $0) }
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
                    if characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
                        peripheral.setNotifyValue(true, for: characteristic)
                    }
                    readStateIfPermitted()
                } else if characteristic.uuid == pairingUUID {
                    pairingCharacteristic = characteristic
                }
            }

            if commandCharacteristic != nil && pairingCharacteristic != nil {
                reconnectTimer?.invalidate()
                connectionState = "Ready"
                sendPendingSystemCommandIfReady()
            } else {
                lastError = "Required controller characteristic not found"
                scheduleReconnectCheck(after: 1)
            }
        }
    }

    private func sendPendingSystemCommandIfReady() {
        guard isReady else { return }

        if let seconds = queuedAutoLockTimeoutSeconds {
            queuedAutoLockTimeoutSeconds = nil
            autoLockSeconds = seconds
            applyAutoLockTimeout()
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

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor in
            if let error {
                if characteristic.uuid != stateUUID || !isReadNotPermitted(error) {
                    lastError = error.localizedDescription
                }
                return
            }

            guard characteristic.uuid == stateUUID, let data = characteristic.value else { return }
            let newState = String(data: data, encoding: .utf8) ?? "unknown"
            servoState = newState
            updatePairingState(from: newState)
            publishWidgetState(newState)
            sendPendingSystemCommandIfReady()
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor in
            if let error {
                if characteristic.uuid == commandUUID, pendingAutoLockTimeoutSeconds != nil {
                    pendingAutoLockTimeoutSeconds = nil
                    autoLockStatus = "Not set"
                }
                lastError = error.localizedDescription
                if characteristic.uuid == pairingUUID {
                    pairingState = "Pairing locked"
                }
                return
            }

            if characteristic.uuid == commandUUID, let seconds = pendingAutoLockTimeoutSeconds {
                pendingAutoLockTimeoutSeconds = nil
                autoLockStatus = "Controller set to \(seconds)s"
                if isUnlocked {
                    publishWidgetState(servoState, resetAutoLockDeadline: true)
                }
                readStateIfPermitted()
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

    private func updatePairingState(from state: String) {
        switch state {
        case "pairing_enabled":
            pairingState = "Pairing enabled"
            pairingApprovalCode = nil
        case "pairing_pending":
            pairingState = "Pairing pending"
            if pairingApprovalCode == nil {
                pairingApprovalCode = try? DoorCommandAuthenticator.pairingFingerprint()
            }
        case "pairing_locked", "unpaired":
            pairingState = "Pairing locked"
            pairingApprovalCode = nil
        case "paired", "locked", "unlocked", "locking", "unlocking", "timeout_set":
            pairingState = "Paired"
            if state == "paired" {
                pairingApprovalCode = nil
            }
        default:
            break
        }
    }
}
