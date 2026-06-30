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

    @Published private(set) var bluetoothState = "Starting"
    @Published private(set) var connectionState = "Disconnected"
    @Published private(set) var deviceName = "DoorUnlocker-XIAO-v2"
    @Published private(set) var servoState = "unknown"
    @Published private(set) var pairingState = "Unknown"
    @Published private(set) var pairingApprovalCode: String?
    @Published private(set) var isAuthenticatingUnlock = false
    @Published private(set) var isAuthenticatingSettings = false
    @Published private(set) var areSettingsUnlocked = false
    @Published private(set) var autoLockSeconds = DoorUnlockerController.storedAutoLockSeconds()
    @Published private(set) var autoLockStatus = "Ready to set"
    @Published private(set) var autoLockRemainingSeconds: Int?
    @Published private(set) var deviceDisplayName = DoorUnlockerController.storedDeviceDisplayName()
    @Published private(set) var deviceDisplayNameStatus = "Ready to sync"
    @Published private(set) var requiresUnlockAuthentication = UserDefaults.standard.bool(forKey: DoorUnlockerController.unlockAuthenticationKey)
    @Published var lastError: String?

    private static let unlockAuthenticationKey = "RequireUnlockAuthentication"
    private static let autoLockSecondsKey = "AutoLockSeconds"
    private static let deviceDisplayNameKey = "DoorUnlockerDeviceDisplayName"
    private static let maximumDeviceDisplayNameLength = 24
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
    private var deviceDisplayNameSyncTask: Task<Void, Never>?
    private var pendingDeviceDisplayName: String?
    private var sentDeviceDisplayName: String?
    private var lastSyncedDeviceDisplayName: String?
    private var liveActivity: Activity<DoorUnlockerActivityAttributes>?
    private var liveActivityCompletionTask: Task<Void, Never>?
    private var isCompletingLiveActivity = false
    private var liveActivityBackgroundTask: UIBackgroundTaskIdentifier = .invalid

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
        dismissStoredLockedLiveActivityIfNeeded()
    }

    private static func storedAutoLockSeconds() -> Int {
        let storedValue = UserDefaults.standard.integer(forKey: autoLockSecondsKey)
        let seconds = storedValue == 0 ? defaultAutoLockSeconds : storedValue
        return clampedAutoLockSeconds(seconds)
    }

    private static func storedDeviceDisplayName() -> String {
        if let storedName = UserDefaults.standard.string(forKey: deviceDisplayNameKey) {
            let sanitizedName = sanitizedDeviceDisplayName(storedName)
            if !sanitizedName.isEmpty {
                return sanitizedName
            }
        }

        return sanitizedDeviceDisplayName(UIDevice.current.name)
    }

    private static func sanitizedDeviceDisplayName(_ name: String) -> String {
        let normalized = name
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = normalized.isEmpty ? "iPhone" : normalized
        let ascii = fallback.unicodeScalars.map { scalar -> String in
            scalar.isASCII && scalar.value >= 32 && scalar.value <= 126 ? String(scalar) : "?"
        }
        return String(ascii.joined().prefix(maximumDeviceDisplayNameLength)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func clampedAutoLockSeconds(_ seconds: Int) -> Int {
        min(max(seconds, minimumAutoLockSeconds), maximumAutoLockSeconds)
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

    func updateAutoLockSeconds(_ seconds: Int) {
        let clampedSeconds = Self.clampedAutoLockSeconds(seconds)
        guard clampedSeconds != autoLockSeconds else { return }
        guard areSettingsUnlocked else {
            lastError = "Open Settings with Face ID or passcode first"
            return
        }

        autoLockSeconds = clampedSeconds
        UserDefaults.standard.set(autoLockSeconds, forKey: Self.autoLockSecondsKey)
        scheduleAutoLockTimeoutApply()
    }

    func updateDeviceDisplayName(_ name: String) {
        let sanitizedName = Self.sanitizedDeviceDisplayName(name)
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
        deviceDisplayNameStatus = isReady ? "Setting..." : "Waiting for controller"
        syncDeviceDisplayNameIfReady()
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

    func pairThisPhone() {
        guard let peripheral, let pairingCharacteristic else {
            lastError = "Pairing characteristic not found"
            return
        }

        do {
            let pairingPayload = try DoorCommandAuthenticator.pairingPayload(deviceName: deviceDisplayName)
            let approvalCode = try DoorCommandAuthenticator.pairingApprovalCode()
            guard pairingPayload.count <= peripheral.maximumWriteValueLength(for: .withResponse) else {
                lastError = "Pairing key is too large for this BLE connection"
                return
            }

            lastError = nil
            pairingApprovalCode = approvalCode
            pairingState = "Pairing"
            peripheral.writeValue(pairingPayload, for: pairingCharacteristic, type: .withResponse)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func syncDeviceDisplayNameIfReady() {
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
            deviceDisplayNameStatus = "Waiting for controller"
            scan()
            return
        }

        if writeAuthenticatedCommand("SET_NAME:\(nameToSync)") {
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

        deviceDisplayNameSyncTask?.cancel()
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

    private func scheduleDeviceDisplayNameRetry() {
        deviceDisplayNameSyncTask?.cancel()
        deviceDisplayNameSyncTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            await self?.retryUnconfirmedDeviceDisplayName()
        }
    }

    private func retryUnconfirmedDeviceDisplayName() {
        guard let name = sentDeviceDisplayName else { return }

        sentDeviceDisplayName = nil
        pendingDeviceDisplayName = name
        deviceDisplayNameStatus = isReady ? "Retrying..." : "Waiting for controller"
        syncDeviceDisplayNameIfReady()
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

    private func publishWidgetState(
        _ state: String,
        updatedAt: Date = .now,
        resetAutoLockDeadline: Bool = false,
        controllerRemainingSeconds: Int? = nil
    ) {
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
        WidgetCenter.shared.reloadTimelines(ofKind: "DoorUnlockerWidget")
        scheduleAutoLockPrediction(deadline: deadline)
        syncLiveActivity(state: state, startedAt: startedAt, deadline: deadline)
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
            let rawState = String(data: data, encoding: .utf8) ?? "unknown"
            let parsedState = parseControllerState(rawState)
            if parsedState.state == "timeout_set" {
                if let seconds = parsedState.remainingSeconds {
                    autoLockSeconds = Self.clampedAutoLockSeconds(seconds)
                    UserDefaults.standard.set(autoLockSeconds, forKey: Self.autoLockSecondsKey)
                    autoLockStatus = "Controller set to \(autoLockSeconds)s"
                }
                updatePairingState(from: parsedState.state)
                syncDeviceDisplayNameIfReady()
                return
            }

            if parsedState.state == "paired" {
                updatePairingState(from: parsedState.state)
                confirmDeviceDisplayNameSyncIfNeeded()
                syncDeviceDisplayNameIfReady()
                return
            }

            servoState = parsedState.state
            updatePairingState(from: parsedState.state)
            publishWidgetState(parsedState.state, controllerRemainingSeconds: parsedState.remainingSeconds)
            sendPendingSystemCommandIfReady()
            syncDeviceDisplayNameIfReady()
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor in
            if let error {
                if characteristic.uuid == commandUUID, pendingAutoLockTimeoutSeconds != nil {
                    pendingAutoLockTimeoutSeconds = nil
                    autoLockStatus = "Not set"
                }
                if characteristic.uuid == commandUUID, let name = sentDeviceDisplayName {
                    deviceDisplayNameSyncTask?.cancel()
                    sentDeviceDisplayName = nil
                    pendingDeviceDisplayName = name
                    deviceDisplayNameStatus = "Not set"
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

            if characteristic.uuid == commandUUID, sentDeviceDisplayName != nil {
                deviceDisplayNameStatus = "Waiting for controller"
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
                pairingApprovalCode = try? DoorCommandAuthenticator.pairingApprovalCode()
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
