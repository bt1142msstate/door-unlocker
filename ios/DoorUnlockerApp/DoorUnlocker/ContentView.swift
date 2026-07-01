import SwiftUI

struct ContentView: View {
    @StateObject private var controller = DoorUnlockerController()
    @Environment(\.scenePhase) private var scenePhase
    @State private var motionPhase = false
    @State private var displayedIconIsUnlocked = false
    @State private var iconFlipDegrees = 0.0
    @State private var settingsExpanded = false
    @State private var deviceDisplayNameDraft = ""
    @State private var deviceDisplayNameCommitTask: Task<Void, Never>?
    @State private var shouldLockSettingsAfterDeviceNameCommit = false
    @State private var isUnlockHoldActive = false
    @State private var unlockHoldProgress = 0.0
    @State private var unlockHoldTask: Task<Void, Never>?
    @FocusState private var isDeviceDisplayNameFocused: Bool

    private var accent: Color {
        controller.isUnlocked ? Color(red: 0.35, green: 0.86, blue: 0.58) : Color(red: 0.35, green: 0.72, blue: 1.0)
    }

    private var actionTitle: String {
        if controller.isAuthenticatingUnlock {
            return "Authenticating..."
        }

        if controller.isChangingState {
            return controller.isUnlocked ? "Locking..." : "Unlocking..."
        }

        if shouldHoldToUnlock {
            return isUnlockHoldActive ? "Keep holding" : "Hold to unlock"
        }

        return controller.isUnlocked ? "Tap to lock" : "Tap to unlock"
    }

    private var modeIcon: String {
        displayedIconIsUnlocked ? "lock.open.fill" : "lock.fill"
    }

    private var shouldHoldToUnlock: Bool {
        controller.requiresHoldToUnlock && !controller.isUnlocked
    }

    private var isPrimaryActionEnabled: Bool {
        controller.isReady && !controller.isBusy
    }

    var body: some View {
        ZStack {
            background

            VStack(spacing: settingsExpanded ? 12 : 18) {
                header
                stateCard
                if settingsExpanded {
                    Spacer(minLength: 0)
                } else {
                    Spacer(minLength: 8)
                    toggleButton
                        .transition(
                            .asymmetric(
                                insertion: .scale(scale: 0.94).combined(with: .opacity),
                                removal: .scale(scale: 0.88).combined(with: .opacity)
                            )
                        )
                    Spacer(minLength: 16)
                }
                footerControls
            }
            .padding(20)
            .animation(.spring(response: 0.32, dampingFraction: 0.78), value: settingsExpanded)
        }
        .onChange(of: controller.isChangingState) { _, isChanging in
            if isChanging {
                motionPhase = false
                withAnimation(.easeInOut(duration: 0.72).repeatForever(autoreverses: true)) {
                    motionPhase = true
                }
            } else {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.72)) {
                    motionPhase = false
                }
            }
        }
        .onChange(of: controller.servoState) { _, state in
            flipLockIcon(for: state)
            if state == "unlocking" || state == "unlocked" {
                cancelUnlockHold()
            }
        }
        .onAppear {
            displayedIconIsUnlocked = controller.isUnlocked
            deviceDisplayNameDraft = controller.deviceDisplayName
            controller.refreshStateFromController()
            controller.performPendingSystemCommand()
        }
        .onChange(of: controller.deviceDisplayName) { _, name in
            if !isDeviceDisplayNameFocused {
                deviceDisplayNameDraft = name
            }
        }
        .onOpenURL { url in
            DoorCommandStore.request(from: url)
            controller.performPendingSystemCommand()
        }
        .onReceive(NotificationCenter.default.publisher(for: .doorCommandRequested)) { _ in
            controller.performPendingSystemCommand()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                controller.refreshNotificationSettings()
                controller.refreshStateFromController()
                controller.performPendingSystemCommand()
            } else {
                closeSettings()
            }
        }
        .onChange(of: controller.areSettingsUnlocked) { _, isUnlocked in
            withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                settingsExpanded = isUnlocked
            }
        }
        .onChange(of: controller.isBusy) { _, isBusy in
            if isBusy {
                cancelUnlockHold()
            }
        }
        .onChange(of: controller.requiresHoldToUnlock) { _, _ in
            cancelUnlockHold()
        }
        .onChange(of: controller.unlockHoldDurationSeconds) { _, _ in
            cancelUnlockHold()
        }
    }

    private var background: some View {
        ZStack {
            Color(red: 0.03, green: 0.04, blue: 0.05)
            LinearGradient(
                colors: [
                    accent.opacity(0.22),
                    Color(red: 0.03, green: 0.04, blue: 0.05),
                    Color(red: 0.09, green: 0.07, blue: 0.05)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .opacity(0.75)
        }
        .ignoresSafeArea()
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(accent.opacity(0.16))
                Image(systemName: "door.left.hand.closed")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(accent)
            }
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 3) {
                Text("Door Unlocker")
                    .font(.title2.weight(.bold))
                Label(controller.deviceName, systemImage: "rectangle.connected.to.line.below")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            Spacer()
        }
        .padding(.top, 10)
    }

    private var stateCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(controller.stateTitle)
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                    Text(controller.isReady ? "Controller connected" : controller.connectionState)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)

                    if let countdownText = controller.autoLockCountdownText {
                        countdownBadge(countdownText)
                    }
                }

                Spacer()

                Image(systemName: controller.isUnlocked ? "lock.open.fill" : "lock.fill")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(accent)
            }

            controllerStatusSummary
            controllerSettings

            if controller.canPair {
                Label("Tap Pair This iPhone, then approve its code over USB-C.", systemImage: "key.fill")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(accent)
            } else if controller.isPairingPending {
                pairingApprovalPanel
            } else if controller.needsUsbPairingMode {
                Label("Enable pairing over USB-C first, then tap Pair This iPhone.", systemImage: "cable.connector")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            if let error = controller.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.yellow)
                    .lineLimit(2)
            }
        }
        .padding(18)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.12))
        }
    }

    private var controllerStatusSummary: some View {
        HStack(spacing: 8) {
            Image(systemName: controllerStatusIcon)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(accent)
                .frame(width: 30, height: 30)
                .background(accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(controllerStatusTitle)
                    .font(.caption.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                Text(controllerStatusDetail)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(Color.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var controllerStatusIcon: String {
        if controller.isReady {
            return "checkmark.circle.fill"
        }

        if controller.bluetoothState != "On" {
            return "exclamationmark.triangle.fill"
        }

        if controller.isPairingPending || controller.needsUsbPairingMode || controller.canPair {
            return "key.fill"
        }

        return "antenna.radiowaves.left.and.right"
    }

    private var controllerStatusTitle: String {
        if controller.isReady {
            return "Controller ready"
        }

        if controller.bluetoothState != "On" {
            return "Bluetooth \(controller.bluetoothState)"
        }

        if controller.connectionState != "Ready" {
            return controller.connectionState
        }

        return controller.pairingState
    }

    private var controllerStatusDetail: String {
        "BT \(controller.bluetoothState) - Link \(controller.connectionState) - Pairing \(controller.pairingState)"
    }

    private func countdownBadge(_ text: String) -> some View {
        Label(text, systemImage: "timer")
            .font(.caption.weight(.bold))
            .lineLimit(1)
            .minimumScaleFactor(0.78)
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(accent.opacity(0.24), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(accent.opacity(0.28))
            }
    }

    private var toggleButton: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.12))

                Circle()
                    .strokeBorder(Color.white.opacity(controller.isChangingState ? 0.34 : 0), lineWidth: 5)
                    .scaleEffect(controller.isChangingState && motionPhase ? 1.2 : 0.9)
                    .opacity(controller.isChangingState && motionPhase ? 0.08 : 0.7)

                Circle()
                    .trim(from: 0.08, to: 0.82)
                    .stroke(
                        Color.white.opacity(controller.isChangingState ? 0.82 : 0),
                        style: StrokeStyle(lineWidth: 6, lineCap: .round)
                    )
                    .rotationEffect(.degrees(controller.isChangingState && motionPhase ? 360 : 0))

                Circle()
                    .trim(from: 0, to: unlockHoldProgress)
                    .stroke(
                        Color.white.opacity(isUnlockHoldActive ? 0.92 : 0),
                        style: StrokeStyle(lineWidth: 7, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))

                Image(systemName: modeIcon)
                    .font(.system(size: 58, weight: .bold))
                    .foregroundStyle(.white)
                    .rotation3DEffect(
                        .degrees(iconFlipDegrees),
                        axis: (x: 0, y: 1, z: 0),
                        perspective: 0.55
                    )
                    .scaleEffect((controller.isBusy && motionPhase) || isUnlockHoldActive ? 0.9 : 1.0)
            }
            .frame(width: 118, height: 118)

            Text(actionTitle)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.86))
        }
        .frame(maxWidth: .infinity)
        .frame(height: 260)
        .background(
            LinearGradient(
                colors: [accent.opacity(0.95), accent.opacity(0.55)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.22))
        }
        .shadow(color: accent.opacity(0.28), radius: 24, y: 14)
        .opacity(isPrimaryActionEnabled ? 1.0 : 0.55)
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .gesture(primaryActionGesture)
        .onDisappear {
            cancelUnlockHold()
        }
        .accessibilityLabel(actionTitle)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(shouldHoldToUnlock ? "Hold until the ring completes." : "")
        .accessibilityAction {
            performPrimaryAction()
        }
    }

    private var primaryActionGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard isPrimaryActionEnabled, shouldHoldToUnlock else { return }
                beginUnlockHold()
            }
            .onEnded { _ in
                if shouldHoldToUnlock {
                    cancelUnlockHold()
                } else {
                    performPrimaryAction()
                }
            }
    }

    private func performPrimaryAction() {
        guard isPrimaryActionEnabled else { return }
        controller.toggleLock()
    }

    private func beginUnlockHold() {
        guard !isUnlockHoldActive, isPrimaryActionEnabled, shouldHoldToUnlock else { return }

        unlockHoldTask?.cancel()
        isUnlockHoldActive = true
        unlockHoldProgress = 0

        let duration = controller.unlockHoldDurationSeconds
        withAnimation(.linear(duration: duration)) {
            unlockHoldProgress = 1
        }

        unlockHoldTask = Task { @MainActor in
            let nanoseconds = UInt64((duration * 1_000_000_000).rounded())
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }

            unlockHoldTask = nil
            isUnlockHoldActive = false
            unlockHoldProgress = 0

            guard isPrimaryActionEnabled, shouldHoldToUnlock else { return }
            controller.send(.unlock)
        }
    }

    private func cancelUnlockHold() {
        unlockHoldTask?.cancel()
        unlockHoldTask = nil

        guard isUnlockHoldActive || unlockHoldProgress > 0 else { return }
        isUnlockHoldActive = false
        withAnimation(.easeOut(duration: 0.16)) {
            unlockHoldProgress = 0
        }
    }

    private func flipLockIcon(for state: String) {
        let targetIsUnlocked: Bool

        switch state {
        case "unlocking", "unlocked":
            targetIsUnlocked = true
        case "locking", "locked":
            targetIsUnlocked = false
        default:
            return
        }

        guard displayedIconIsUnlocked != targetIsUnlocked else { return }

        withAnimation(.easeIn(duration: 0.18)) {
            iconFlipDegrees = 90
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            displayedIconIsUnlocked = targetIsUnlocked
            iconFlipDegrees = -90

            withAnimation(.easeOut(duration: 0.22)) {
                iconFlipDegrees = 0
            }
        }
    }

    @ViewBuilder
    private var footerControls: some View {
        if controller.canPair {
            Button {
                controller.pairThisPhone()
            } label: {
                Label("Pair This iPhone", systemImage: "key.fill")
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    private var controllerSettings: some View {
        DisclosureGroup(isExpanded: Binding(
            get: { settingsExpanded },
            set: { wantsExpanded in
                if wantsExpanded {
                    openSettings()
                } else {
                    closeSettings()
                }
            }
        )) {
            VStack(spacing: 10) {
                unlockGestureControl
                unlockAuthenticationToggle
                unlockNotificationsToggle
                deviceDisplayNameControl
                autoLockTimeoutControl
            }
            .padding(.top, 10)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "slider.horizontal.3")
                    .foregroundStyle(accent)
                Text("Settings")
                    .font(.caption.weight(.bold))
                Spacer(minLength: 8)
                Text(settingsDisclosureActionText)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
        }
        .tint(accent)
        .padding(12)
        .background(Color.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var unlockGestureControl: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "hand.tap.fill")
                    .foregroundStyle(accent)
                Text("Unlock Gesture")
                    .font(.caption.weight(.bold))
                Spacer(minLength: 8)
                Text(controller.requiresHoldToUnlock ? "Hold" : "Tap")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }

            Picker("Unlock Gesture", selection: Binding(
                get: { controller.requiresHoldToUnlock },
                set: { controller.setRequiresHoldToUnlock($0) }
            )) {
                Text("Tap").tag(false)
                Text("Hold").tag(true)
            }
            .pickerStyle(.segmented)

            if controller.requiresHoldToUnlock {
                Stepper(
                    value: Binding(
                        get: { controller.unlockHoldDurationSeconds },
                        set: { controller.updateUnlockHoldDurationSeconds($0) }
                    ),
                    in: controller.unlockHoldDurationRange,
                    step: 0.25
                ) {
                    HStack(spacing: 8) {
                        Image(systemName: "timer")
                            .foregroundStyle(accent)
                        Text("Hold Time")
                            .font(.caption.weight(.bold))
                        Spacer(minLength: 8)
                        Text(formattedDuration(controller.unlockHoldDurationSeconds))
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .disabled(controller.isAuthenticatingSettings)
        .padding(12)
        .background(Color.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var unlockAuthenticationToggle: some View {
        Toggle(isOn: Binding(
            get: { controller.requiresUnlockAuthentication },
            set: { controller.setRequiresUnlockAuthentication($0) }
        )) {
            HStack(spacing: 8) {
                Image(systemName: "faceid")
                    .foregroundStyle(accent)
                Text("Face ID / Passcode")
                    .font(.caption.weight(.bold))
                Spacer(minLength: 8)
                Text(controller.requiresUnlockAuthentication ? "On" : "Off")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
        .tint(accent)
        .disabled(controller.isAuthenticatingSettings)
        .padding(12)
        .background(Color.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var unlockNotificationsToggle: some View {
        Toggle(isOn: Binding(
            get: { controller.unlockNotificationsEnabled },
            set: { controller.setUnlockNotificationsEnabled($0) }
        )) {
            HStack(spacing: 8) {
                Image(systemName: "bell.badge.fill")
                    .foregroundStyle(accent)
                Text("Unlock Notifications")
                    .font(.caption.weight(.bold))
                Spacer(minLength: 8)
                Text(controller.unlockNotificationStatus)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .toggleStyle(.switch)
        .tint(accent)
        .disabled(controller.isAuthenticatingSettings)
        .padding(12)
        .background(Color.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var deviceDisplayNameControl: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "iphone.gen3")
                    .foregroundStyle(accent)
                Text("This iPhone")
                    .font(.caption.weight(.bold))
                Spacer(minLength: 8)
                Text(controller.deviceDisplayName)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            TextField("iPhone Air", text: $deviceDisplayNameDraft)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.done)
                .focused($isDeviceDisplayNameFocused)
                .onSubmit {
                    scheduleDeviceDisplayNameCommit()
                }
                .onChange(of: isDeviceDisplayNameFocused) { _, isFocused in
                    if !isFocused {
                        scheduleDeviceDisplayNameCommit()
                    }
                }

            Text(controller.deviceDisplayNameStatus)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .disabled(controller.isAuthenticatingSettings)
        .padding(12)
        .background(Color.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var autoLockTimeoutControl: some View {
        VStack(alignment: .leading, spacing: 10) {
            Stepper(
                value: Binding(
                    get: { controller.autoLockSeconds },
                    set: { controller.updateAutoLockSeconds($0) }
                ),
                in: controller.autoLockRange,
                step: 5
            ) {
                HStack(spacing: 8) {
                    Image(systemName: "timer")
                        .foregroundStyle(accent)
                    Text("Auto-lock")
                        .font(.caption.weight(.bold))
                    Spacer(minLength: 8)
                    Text("\(controller.autoLockSeconds)s")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                }
            }

            Text(controller.autoLockStatus)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .disabled(controller.isAuthenticatingSettings)
        .padding(12)
        .background(Color.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func formattedDuration(_ seconds: Double) -> String {
        if abs(seconds.rounded() - seconds) < 0.001 {
            return "\(Int(seconds))s"
        }

        let tenths = (seconds * 10).rounded() / 10
        if abs(tenths - seconds) < 0.001 {
            return String(format: "%.1fs", seconds)
        }

        return String(format: "%.2fs", seconds)
    }

    private var pairingApprovalPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Enter this code in the Mac app.", systemImage: "keyboard.fill")
                .font(.footnote.weight(.medium))
                .foregroundStyle(accent)

            if let code = controller.pairingApprovalCode {
                Text(code)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .tracking(6)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .background(Color.black.opacity(0.34), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }

    private func scheduleDeviceDisplayNameCommit(lockSettingsAfterCommit: Bool = false) {
        if lockSettingsAfterCommit {
            shouldLockSettingsAfterDeviceNameCommit = true
        }

        deviceDisplayNameCommitTask?.cancel()
        deviceDisplayNameCommitTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }

            deviceDisplayNameCommitTask = nil
            commitDeviceDisplayNameNow()

            if shouldLockSettingsAfterDeviceNameCommit {
                shouldLockSettingsAfterDeviceNameCommit = false
                controller.lockSettings()
            }
        }
    }

    private func cancelPendingDeviceDisplayNameCommit() {
        deviceDisplayNameCommitTask?.cancel()
        deviceDisplayNameCommitTask = nil
        shouldLockSettingsAfterDeviceNameCommit = false
    }

    private func commitDeviceDisplayNameNow() {
        let trimmedName = deviceDisplayNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty {
            deviceDisplayNameDraft = controller.deviceDisplayName
            return
        }

        guard trimmedName != controller.deviceDisplayName else {
            deviceDisplayNameDraft = controller.deviceDisplayName
            return
        }

        controller.updateDeviceDisplayName(trimmedName)
        deviceDisplayNameDraft = controller.deviceDisplayName
    }

    private var settingsDisclosureActionText: String {
        if controller.isAuthenticatingSettings {
            return "Opening"
        }

        return settingsExpanded ? "Hide" : "Show"
    }

    private func openSettings() {
        if controller.areSettingsUnlocked {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                settingsExpanded = true
            }
        } else {
            controller.unlockSettings()
        }
    }

    private func closeSettings() {
        if isDeviceDisplayNameFocused {
            isDeviceDisplayNameFocused = false
            scheduleDeviceDisplayNameCommit(lockSettingsAfterCommit: true)
        } else if deviceDisplayNameCommitTask != nil {
            shouldLockSettingsAfterDeviceNameCommit = true
        } else {
            cancelPendingDeviceDisplayNameCommit()
            deviceDisplayNameDraft = controller.deviceDisplayName
            controller.lockSettings()
        }

        withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
            settingsExpanded = false
        }
    }
}

#Preview {
    ContentView()
}
