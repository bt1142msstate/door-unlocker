import MapKit
import SwiftUI

private enum DoorAppTheme: String, CaseIterable, Identifiable {
    case original
    case monochrome
    case gold
    case aurora
    case pink
    case red
    case ember
    case violet

    var id: String { rawValue }

    var title: String {
        switch self {
        case .original:
            return "Original"
        case .monochrome:
            return "Mono"
        case .gold:
            return "Gold"
        case .aurora:
            return "Aurora"
        case .pink:
            return "Pink"
        case .red:
            return "Red"
        case .ember:
            return "Ember"
        case .violet:
            return "Violet"
        }
    }

    var subtitle: String {
        switch self {
        case .original:
            return "Green / blue"
        case .monochrome:
            return "Black / white"
        case .gold:
            return "Gold / black"
        case .aurora:
            return "Mint / cyan"
        case .pink:
            return "Rose / pink"
        case .red:
            return "Red / ruby"
        case .ember:
            return "Gold / coral"
        case .violet:
            return "Lilac / indigo"
        }
    }

    var unlockedColor: Color {
        switch self {
        case .original:
            return Color(red: 0.35, green: 0.86, blue: 0.58)
        case .monochrome:
            return Color(red: 0.96, green: 0.97, blue: 0.94)
        case .gold:
            return Color(red: 1.00, green: 0.78, blue: 0.24)
        case .aurora:
            return Color(red: 0.30, green: 0.92, blue: 0.72)
        case .pink:
            return Color(red: 1.00, green: 0.45, blue: 0.74)
        case .red:
            return Color(red: 1.00, green: 0.30, blue: 0.34)
        case .ember:
            return Color(red: 1.00, green: 0.70, blue: 0.30)
        case .violet:
            return Color(red: 0.80, green: 0.58, blue: 1.00)
        }
    }

    var lockedColor: Color {
        switch self {
        case .original:
            return Color(red: 0.35, green: 0.72, blue: 1.0)
        case .monochrome:
            return Color(red: 0.64, green: 0.66, blue: 0.62)
        case .gold:
            return Color(red: 0.95, green: 0.50, blue: 0.10)
        case .aurora:
            return Color(red: 0.34, green: 0.76, blue: 1.0)
        case .pink:
            return Color(red: 0.82, green: 0.35, blue: 1.00)
        case .red:
            return Color(red: 0.72, green: 0.08, blue: 0.18)
        case .ember:
            return Color(red: 1.00, green: 0.40, blue: 0.30)
        case .violet:
            return Color(red: 0.44, green: 0.48, blue: 1.00)
        }
    }

    var backgroundTail: Color {
        switch self {
        case .original:
            return Color(red: 0.09, green: 0.07, blue: 0.05)
        case .monochrome:
            return Color(red: 0.00, green: 0.00, blue: 0.00)
        case .gold:
            return Color(red: 0.10, green: 0.07, blue: 0.02)
        case .aurora:
            return Color(red: 0.02, green: 0.09, blue: 0.08)
        case .pink:
            return Color(red: 0.13, green: 0.04, blue: 0.10)
        case .red:
            return Color(red: 0.13, green: 0.03, blue: 0.04)
        case .ember:
            return Color(red: 0.12, green: 0.06, blue: 0.03)
        case .violet:
            return Color(red: 0.08, green: 0.05, blue: 0.13)
        }
    }

    func accent(isUnlocked: Bool) -> Color {
        isUnlocked ? unlockedColor : lockedColor
    }
}

struct ContentView: View {
    @EnvironmentObject private var controller: DoorUnlockerController
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("DoorUnlockerAppTheme") private var appThemeRawValue = DoorAppTheme.original.rawValue
    @State private var motionPhase = false
    @State private var displayedIconIsUnlocked = false
    @State private var iconFlipDegrees = 0.0
    @State private var iconFlipTask: Task<Void, Never>?
    @State private var settingsExpanded = false
    @State private var lockNameDraft = ""
    @State private var lockNameCommitTask: Task<Void, Never>?
    @State private var deviceDisplayNameDraft = ""
    @State private var deviceDisplayNameCommitTask: Task<Void, Never>?
    @State private var shouldLockSettingsAfterNameCommits = false
    @State private var isUnlockHoldActive = false
    @State private var unlockHoldProgress = 0.0
    @State private var unlockHoldTask: Task<Void, Never>?
    @State private var lockZoneMapPosition: MapCameraPosition = .automatic
    @State private var isLockZoneMapExpanded = false
    @FocusState private var isLockNameFocused: Bool
    @FocusState private var isDeviceDisplayNameFocused: Bool

    private var appTheme: DoorAppTheme {
        DoorAppTheme(rawValue: appThemeRawValue) ?? .original
    }

    private var accent: Color {
        appTheme.accent(isUnlocked: controller.isUnlocked)
    }

    private var actionTitle: String {
        if controller.isAuthenticatingUnlock {
            return "Authenticating..."
        }

        if controller.isChangingState {
            if controller.servoState == "locking" {
                return "Locking..."
            }

            if controller.servoState == "unlocking" {
                return "Unlocking..."
            }

            return controller.isUnlocked ? "Locking..." : "Unlocking..."
        }

        if isApplyingSettingsOnly {
            return controller.controllerSettingApplyTitle
        }

        if controller.isReady && !controller.isDoorCommandReady {
            return controller.secureLinkActionTitle
        }

        if shouldHoldToUnlock {
            return isUnlockHoldActive ? "Keep holding" : "Hold to unlock"
        }

        return controller.isUnlocked ? "Tap to lock" : "Tap to unlock"
    }

    private var shouldShowLockControl: Bool {
        controller.isReady || controller.isChangingState || controller.isAuthenticatingUnlock || isApplyingSettingsOnly
    }

    private var primaryPanelTitle: String {
        shouldShowLockControl ? actionTitle : controllerStatusTitle
    }

    private var primaryPanelDetail: String? {
        shouldShowLockControl ? nil : controllerStatusDetail
    }

    private var primaryPanelOpacity: Double {
        if shouldShowLockControl {
            return isPrimaryActionEnabled ? 1.0 : 0.76
        }

        return 1.0
    }

    private var modeIcon: String {
        displayedIconIsUnlocked ? "lock.open.fill" : "lock.fill"
    }

    private var shouldHoldToUnlock: Bool {
        controller.requiresHoldToUnlock && !controller.isUnlocked
    }

    private var isApplyingSettingsOnly: Bool {
        controller.isApplyingControllerSetting && !controller.isChangingState
    }

    private var isPrimaryActionEnabled: Bool {
        controller.isDoorCommandReady && !controller.isBusy && !controller.isApplyingControllerSetting
    }

    var body: some View {
        ZStack {
            background

            GeometryReader { proxy in
                ScrollView {
                    mainContent
                        .frame(minHeight: proxy.size.height, alignment: .top)
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollDismissesKeyboard(.interactively)
            }
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
            lockNameDraft = controller.lockName
            deviceDisplayNameDraft = controller.deviceDisplayName
            controller.refreshStateFromController()
            controller.performPendingSystemCommand()
        }
        .onChange(of: controller.lockName) { _, name in
            if !isLockNameFocused {
                lockNameDraft = name
            }
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
        .fullScreenCover(isPresented: $isLockZoneMapExpanded) {
            LockZoneExpandedMapView(controller: controller, accent: accent)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                controller.cancelForceQuitReliabilityWarning()
                controller.refreshNotificationSettings()
                controller.refreshStateFromController()
                controller.performPendingSystemCommand()
            } else if phase == .background {
                isLockZoneMapExpanded = false
                controller.prepareForceQuitReliabilityWarningIfNeeded()
                closeSettings()
            } else {
                isLockZoneMapExpanded = false
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

    private var mainContent: some View {
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

    private var background: some View {
        ZStack {
            Color(red: 0.03, green: 0.04, blue: 0.05)
            LinearGradient(
                colors: [
                    accent.opacity(0.22),
                    Color(red: 0.03, green: 0.04, blue: 0.05),
                    appTheme.backgroundTail
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
                Text(controller.lockName)
                    .font(.title2.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
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
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(controller.stateTitle)
                            .font(.system(size: 34, weight: .bold, design: .rounded))

                        if controller.isApplyingControllerSetting {
                            SettingsApplyBadge(title: controller.controllerSettingApplyTitle, accent: accent)
                                .transition(.scale(scale: 0.92).combined(with: .opacity))
                        }
                    }

                    if let countdownText = controller.autoLockCountdownText {
                        countdownBadge(countdownText)
                    }
                }

                Spacer()
            }

            controllerStatusSummary
            connectedDevicesSummary
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
            ZStack {
                if controllerStatusIsSearching {
                    ScanningStatusPulse(accent: accent)
                }

                Image(systemName: controllerStatusIcon)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(accent)
            }
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
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(Color.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var connectedDevicesSummary: some View {
        if controller.connectedDeviceCount > 0 || controller.isReady {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(accent)
                    Text("Connected Devices")
                        .font(.caption.weight(.bold))
                    Spacer(minLength: 8)
                    Text(controller.connectedDevicesTitle)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                }

                Text(controller.connectedDevicesDetail)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.76)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.08))
            }
            .accessibilityElement(children: .combine)
        }
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

    private var controllerStatusIsSearching: Bool {
        switch controller.connectionState {
        case "Scanning", "Connecting", "Discovering", "Reconnecting", "Restoring", "Starting", "Known controller":
            return controller.bluetoothState == "On"
        default:
            return false
        }
    }

    private var controllerStatusTitle: String {
        if controller.isReady {
            return controller.isDoorCommandReady ? "Controller is ready." : controller.secureLinkStatusTitle
        }

        if controller.bluetoothState != "On" {
            return bluetoothStatusTitle
        }

        switch controller.connectionState {
        case "Scanning":
            return "Bluetooth is scanning."
        case "Connecting":
            return "Connecting to the controller."
        case "Discovering":
            return "Checking controller features."
        case "Reconnecting":
            return "Reconnecting to the controller."
        case "Restoring":
            return "Restoring the controller link."
        case "Disconnected":
            return "The controller is disconnected."
        case "Known controller":
            return "Opening the saved controller link."
        case "Bluetooth off":
            return "Bluetooth is off."
        case "Permission needed":
            return "Bluetooth permission is needed."
        case "Unsupported":
            return "Bluetooth is not supported."
        case "Resetting":
            return "Bluetooth is resetting."
        case "Starting":
            return "Bluetooth is starting."
        case "Ready":
            break
        default:
            if controller.connectionState != "Ready" {
                return connectionStatusSentence
            }
        }

        if controller.isPairingPending {
            return "Waiting for pairing approval."
        }

        if controller.canPair {
            return "This iPhone can pair now."
        }

        if controller.needsUsbPairingMode {
            return "Pairing is locked."
        }

        return pairingStatusSentence
    }

    private var controllerStatusDetail: String {
        if controller.isReady {
            return controller.isDoorCommandReady
                ? "Bluetooth is on. This iPhone is paired with the lock."
                : controller.secureLinkStatusDetail
        }

        if controller.bluetoothState != "On" {
            return bluetoothStatusDetail
        }

        switch controller.connectionState {
        case "Scanning":
            return "Looking for your lock nearby."
        case "Connecting":
            return "The app found the controller and is opening the link."
        case "Discovering":
            return "The app is preparing secure lock control."
        case "Reconnecting":
            return "The app is trying to restore control automatically."
        case "Restoring":
            return "iOS is handing the saved Bluetooth link back to the app."
        case "Disconnected":
            return "The app will reconnect when it sees the controller again."
        case "Known controller":
            return "The app found the saved lock and is preparing control."
        case "Bluetooth off":
            return "Turn on Bluetooth to control the lock."
        case "Permission needed":
            return "Allow Bluetooth access in Settings to connect."
        case "Unsupported":
            return "This device cannot control the lock over Bluetooth."
        case "Resetting":
            return "The app will reconnect when Bluetooth is ready."
        case "Starting":
            return "The app is waiting for Bluetooth to become ready."
        case "Ready":
            break
        default:
            if controller.connectionState != "Ready" {
                return "Bluetooth is on. \(connectionStatusSentence)"
            }
        }

        if controller.isPairingPending {
            return "Enter the code shown here in the Mac app to finish pairing."
        }

        if controller.canPair {
            return "Tap Pair This iPhone, then approve the code over USB-C."
        }

        if controller.needsUsbPairingMode {
            return "Use the Mac app over USB-C to allow a new phone."
        }

        return "The controller is connected. \(pairingStatusSentence)"
    }

    private var bluetoothStatusTitle: String {
        switch controller.bluetoothState {
        case "On":
            return "Bluetooth is on."
        case "Off":
            return "Bluetooth is off."
        case "Unauthorized":
            return "Bluetooth permission is needed."
        case "Unsupported":
            return "Bluetooth is not supported."
        case "Resetting":
            return "Bluetooth is resetting."
        case "Starting":
            return "Bluetooth is starting."
        case "Unknown":
            return "Bluetooth status is unknown."
        default:
            return "Bluetooth is \(controller.bluetoothState.lowercased())."
        }
    }

    private var bluetoothStatusDetail: String {
        switch controller.bluetoothState {
        case "On":
            return "The app can look for the lock."
        case "Off":
            return "Turn on Bluetooth to control the lock."
        case "Unauthorized":
            return "Allow Bluetooth access in Settings to connect."
        case "Unsupported":
            return "This device cannot control the lock over Bluetooth."
        case "Resetting":
            return "The app will reconnect when Bluetooth is ready."
        case "Starting":
            return "The app is waiting for Bluetooth to become ready."
        case "Unknown":
            return "The app is waiting for iOS to report Bluetooth status."
        default:
            return "The app cannot connect while Bluetooth is unavailable."
        }
    }

    private var connectionStatusSentence: String {
        switch controller.connectionState {
        case "Ready":
            return "The controller is ready."
        case "Scanning":
            return "Bluetooth is scanning for the lock."
        case "Connecting":
            return "The app is connecting to the controller."
        case "Discovering":
            return "The app is checking controller features."
        case "Reconnecting":
            return "The app is reconnecting to the controller."
        case "Restoring":
            return "The app is restoring the controller link."
        case "Disconnected":
            return "The controller is disconnected."
        case "Known controller":
            return "The app is opening the saved controller link."
        case "Bluetooth off":
            return "Bluetooth is off."
        case "Permission needed":
            return "Bluetooth permission is needed."
        case "Unsupported":
            return "Bluetooth is not supported."
        case "Resetting":
            return "Bluetooth is resetting."
        case "Starting":
            return "Bluetooth is starting."
        default:
            return "The controller link is being checked."
        }
    }

    private var pairingStatusSentence: String {
        switch controller.pairingState {
        case "Paired":
            return "This iPhone is paired."
        case "Pairing enabled":
            return "Pairing is enabled."
        case "Pairing pending":
            return "Pairing is waiting for Mac approval."
        case "Pairing":
            return "This iPhone is sending a pairing request."
        case "Pairing locked":
            return "Pairing must be enabled over USB-C."
        case "Unknown":
            return "The app is checking pairing."
        default:
            return "The app is checking pairing."
        }
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
        VStack(spacing: primaryPanelDetail == nil ? 14 : 10) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.12))

                if shouldShowLockControl {
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

                    Group {
                        if isApplyingSettingsOnly {
                            SettingsApplyIcon(size: 58)
                        } else {
                            Image(systemName: modeIcon)
                                .font(.system(size: 58, weight: .bold))
                                .rotation3DEffect(
                                    .degrees(iconFlipDegrees),
                                    axis: (x: 0, y: 1, z: 0),
                                    perspective: 0.55
                                )
                        }
                    }
                    .foregroundStyle(.white)
                    .scaleEffect((controller.isChangingState && motionPhase) || isUnlockHoldActive ? 0.9 : 1.0)
                } else {
                    ConnectionStatusAnimation(
                        icon: controllerStatusIcon,
                        accent: accent,
                        isSearching: controllerStatusIsSearching
                    )
                }
            }
            .frame(width: 118, height: 118)

            Text(primaryPanelTitle)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.86))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.72)

            if let primaryPanelDetail {
                Text(primaryPanelDetail)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.68))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.78)
                    .padding(.horizontal, 24)
            }
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
        .opacity(primaryPanelOpacity)
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .gesture(primaryActionGesture)
        .onDisappear {
            cancelUnlockHold()
            iconFlipTask?.cancel()
            iconFlipTask = nil
        }
        .accessibilityLabel(primaryPanelTitle)
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
        iconFlipTask?.cancel()
        iconFlipTask = nil

        let targetIsUnlocked: Bool

        switch state {
        case "unlocking", "unlocked":
            targetIsUnlocked = true
        case "locking", "locked":
            targetIsUnlocked = false
        default:
            return
        }

        guard displayedIconIsUnlocked != targetIsUnlocked else {
            withAnimation(.easeOut(duration: 0.16)) {
                iconFlipDegrees = 0
            }
            return
        }

        withAnimation(.easeIn(duration: 0.18)) {
            iconFlipDegrees = 90
        }

        iconFlipTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }

            displayedIconIsUnlocked = targetIsUnlocked
            iconFlipDegrees = -90

            withAnimation(.easeOut(duration: 0.22)) {
                iconFlipDegrees = 0
            }

            iconFlipTask = nil
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
                lockNameControl
                appearanceThemeControl
                unlockGestureControl
                unlockAuthenticationToggle
                proximityUnlockToggle
                proximityLockZoneCard
                unlockNotificationsToggle
                deviceDisplayNameControl
                autoLockTimeoutControl
                servoAnglesControl
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

    private var appearanceThemeControl: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "paintpalette.fill")
                    .foregroundStyle(accent)
                Text("Color Scheme")
                    .font(.caption.weight(.bold))
                Spacer(minLength: 8)
                Text(appTheme.title)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], spacing: 8) {
                ForEach(DoorAppTheme.allCases) { theme in
                    ThemeSwatchButton(
                        theme: theme,
                        isSelected: theme == appTheme,
                        action: {
                            appThemeRawValue = theme.rawValue
                        }
                    )
                }
            }
        }
        .disabled(controller.isAuthenticatingSettings)
        .padding(12)
        .background(Color.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var lockNameControl: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "door.left.hand.closed")
                    .foregroundStyle(accent)
                Text("Lock Name")
                    .font(.caption.weight(.bold))
            }

            TextField(DoorStatusStore.defaultLockName, text: $lockNameDraft)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.done)
                .focused($isLockNameFocused)
                .onSubmit {
                    scheduleLockNameCommit()
                }
                .onChange(of: isLockNameFocused) { _, isFocused in
                    if !isFocused {
                        scheduleLockNameCommit()
                    }
                }

            Text(controller.lockNameStatus)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .disabled(controller.isAuthenticatingSettings)
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

    private var proximityUnlockToggle: some View {
        Toggle(isOn: Binding(
            get: { controller.proximityUnlockEnabled },
            set: { controller.setProximityUnlockEnabled($0) }
        )) {
            HStack(spacing: 8) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .foregroundStyle(accent)
                Text("Proximity Unlock")
                    .font(.caption.weight(.bold))
                Spacer(minLength: 8)
                Text(controller.proximityUnlockStatus)
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

    private var proximityLockZoneCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "map.fill")
                    .foregroundStyle(accent)
                Text("Lock Zone")
                    .font(.caption.weight(.bold))
                Spacer(minLength: 8)
                Text(controller.lockZoneStatus)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }

            if let center = controller.lockZoneCenter {
                Map(
                    position: $lockZoneMapPosition,
                    interactionModes: [.pan, .zoom]
                ) {
                    MapPolyline(coordinates: lockZoneRingCoordinates(center: center, radius: controller.lockZoneRadiusMeters))
                        .stroke(accent.opacity(0.28), lineWidth: 8)
                        .mapOverlayLevel(level: .aboveRoads)
                    MapPolyline(coordinates: lockZoneRingCoordinates(center: center, radius: controller.lockZoneRadiusMeters))
                        .stroke(accent.opacity(0.92), lineWidth: 2)
                        .mapOverlayLevel(level: .aboveRoads)
                    Marker("Lock", systemImage: "lock.fill", coordinate: center)
                        .tint(accent)
                    if let userLocation = controller.lockZoneUserLocation {
                        Annotation("You", coordinate: userLocation, anchor: .center) {
                            ZStack {
                                Circle()
                                    .fill(Color.black.opacity(0.56))
                                    .frame(width: 28, height: 28)
                                Circle()
                                    .fill(accent)
                                    .frame(width: 14, height: 14)
                                Circle()
                                    .stroke(accent.opacity(0.75), lineWidth: 2)
                                    .frame(width: 24, height: 24)
                            }
                        }
                    }
                }
                .mapControls {
                    MapCompass()
                    MapScaleView()
                }
                .frame(height: 190)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.white.opacity(0.12))
                }
                .overlay(alignment: .bottomTrailing) {
                    HStack(spacing: 8) {
                        Button {
                            isLockZoneMapExpanded = true
                        } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)
                                .frame(width: 34, height: 34)
                                .background(Color.black.opacity(0.62), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Expand lock zone map")

                        Button {
                            syncLockZoneMapCamera()
                        } label: {
                            Image(systemName: "scope")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)
                                .frame(width: 34, height: 34)
                                .background(Color.black.opacity(0.62), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Center lock zone")
                    }
                    .padding(10)
                }
                .onAppear {
                    syncLockZoneMapCamera(animated: false)
                    controller.startLockZoneLocationUpdates()
                }
                .onDisappear {
                    controller.stopLockZoneLocationUpdates()
                }
                .onChange(of: lockZoneMapTargetID) { _, _ in
                    syncLockZoneMapCamera()
                    controller.refreshLockZoneLocation()
                }

                VStack(alignment: .leading, spacing: 8) {
                    Label(controller.lockZoneLocationSummary, systemImage: controller.lockZoneLocationSystemImage)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Label(controller.proximityUnlockDetail, systemImage: "dot.radiowaves.left.and.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "ruler.fill")
                            .foregroundStyle(accent)
                        Text("Distance Units")
                            .font(.caption.weight(.bold))
                        Spacer(minLength: 8)
                        Text(controller.distanceUnit.title)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                    }

                    Picker("Distance Units", selection: Binding(
                        get: { controller.distanceUnit },
                        set: { controller.setDistanceUnit($0) }
                    )) {
                        ForEach(DoorUnlockerController.DistanceUnit.allCases) { unit in
                            Text(unit.title).tag(unit)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Toggle(isOn: Binding(
                        get: { controller.proximityUnlockRSSIGateEnabled },
                        set: { controller.setProximityUnlockRSSIGateEnabled($0) }
                    )) {
                        HStack(spacing: 8) {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .foregroundStyle(accent)
                            Text("Bluetooth Trigger")
                                .font(.caption.weight(.bold))
                            Spacer(minLength: 8)
                            Text(controller.proximityUnlockRSSIThresholdTitle)
                                .font(.caption2.monospacedDigit().weight(.bold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    .tint(accent)

                    if controller.proximityUnlockRSSIGateEnabled {
                        Slider(
                            value: Binding(
                                get: { Double(controller.proximityUnlockRSSISliderValue) },
                                set: { controller.updateProximityUnlockRSSIThreshold(Int($0.rounded())) }
                            ),
                            in: Double(controller.proximityUnlockRSSIThresholdRange.lowerBound) ... Double(controller.proximityUnlockRSSIThresholdRange.upperBound),
                            step: 1
                        )
                        .tint(accent)

                        HStack {
                            Text("Farther")
                            Spacer()
                            Text(controller.currentBluetoothSignalTitle)
                            Spacer()
                            Text("Closer")
                        }
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        Text("Radius")
                            .font(.caption.weight(.bold))
                        Spacer(minLength: 8)
                        Text(formattedDistance(controller.lockZoneRadiusMeters))
                            .font(.caption2.monospacedDigit().weight(.bold))
                            .foregroundStyle(.secondary)
                    }

                    Slider(
                        value: Binding(
                            get: { controller.lockZoneRadiusMeters },
                            set: { controller.updateLockZoneRadiusMeters($0) }
                        ),
                        in: controller.lockZoneRadiusRange,
                        step: 1
                    )
                    .tint(accent)

                    HStack {
                        Text(formattedDistance(controller.lockZoneRadiusRange.lowerBound))
                        Spacer()
                        Text(formattedDistance(controller.lockZoneRadiusRange.upperBound))
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                }

                if let updatedTitle = controller.lockZoneUpdatedTitle {
                    Label("Updated \(updatedTitle)", systemImage: "location.fill")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "location.circle.fill")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(accent)
                    Text("Unlock once to set the zone.")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(12)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            Button {
                controller.setLockZoneToCurrentLocation()
            } label: {
                Label("Use Current Location", systemImage: "location.fill")
                    .font(.caption.weight(.bold))
                    .frame(maxWidth: .infinity, minHeight: 34)
            }
            .buttonStyle(.bordered)
            .tint(accent)
        }
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

            Text("Lock after \(controller.autoLockSeconds) seconds")
                .font(.callout.weight(.semibold))
                .contentTransition(.numericText())

            Slider(
                value: Binding(
                    get: { Double(controller.autoLockSeconds) },
                    set: { controller.updateAutoLockSeconds(Int($0.rounded())) }
                ),
                in: Double(controller.autoLockRange.lowerBound) ... Double(controller.autoLockRange.upperBound),
                step: 5
            )
            .tint(accent)

            HStack {
                Text("\(controller.autoLockRange.lowerBound)s")
                Spacer()
                Text("\(controller.autoLockRange.upperBound)s")
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)

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

    private var servoAnglesControl: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "dial.low")
                    .foregroundStyle(accent)
                Text("Servo Angles")
                    .font(.caption.weight(.bold))
                Spacer(minLength: 8)
                Text("\(controller.servoLockAngle)° / \(controller.servoUnlockAngle)°")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }

            servoAngleSlider(
                title: "Rest angle",
                value: controller.servoLockAngle,
                setValue: controller.updateServoLockAngle
            )

            servoAngleSlider(
                title: "Push angle",
                value: controller.servoUnlockAngle,
                setValue: controller.updateServoUnlockAngle
            )

            if !controller.servoAnglesAreAtDefaults {
                Button {
                    controller.resetServoAnglesToDefaults()
                } label: {
                    Label("Reset to Defaults", systemImage: "arrow.counterclockwise")
                        .font(.caption.weight(.bold))
                        .frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.bordered)
                .tint(accent)
            }

            Text("\(controller.servoAnglesStatus) - safe range \(controller.servoAngleRange.lowerBound)°-\(controller.servoAngleRange.upperBound)°, keep \(DoorUnlockerController.minimumServoAngleGap)° apart")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
        }
        .disabled(controller.isAuthenticatingSettings)
        .padding(12)
        .background(Color.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func servoAngleSlider(title: String, value: Int, setValue: @escaping (Int) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.caption.weight(.bold))
                Spacer(minLength: 8)
                Text("\(value)°")
                    .font(.caption2.monospacedDigit().weight(.bold))
                    .foregroundStyle(.secondary)
            }

            Slider(
                value: Binding(
                    get: { Double(value) },
                    set: { setValue(Int($0.rounded())) }
                ),
                in: Double(controller.servoAngleRange.lowerBound) ... Double(controller.servoAngleRange.upperBound),
                step: 1
            )
            .tint(accent)
        }
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

    private func formattedDistance(_ meters: Double) -> String {
        controller.formattedDistance(meters)
    }

    private func lockZoneRegion(center: CLLocationCoordinate2D, radius: CLLocationDistance) -> MKCoordinateRegion {
        LockZoneMapGeometry.compactRegion(center: center, radius: radius)
    }

    private func lockZoneRingCoordinates(center: CLLocationCoordinate2D, radius: CLLocationDistance) -> [CLLocationCoordinate2D] {
        LockZoneMapGeometry.ringCoordinates(center: center, radius: radius)
    }

    private var lockZoneMapTargetID: String {
        guard let center = controller.lockZoneCenter else { return "none" }
        return [
            String(format: "%.6f", center.latitude),
            String(format: "%.6f", center.longitude),
            String(Int(controller.lockZoneRadiusMeters.rounded()))
        ].joined(separator: ":")
    }

    private func syncLockZoneMapCamera(animated: Bool = true) {
        guard let center = controller.lockZoneCenter else { return }
        let position = MapCameraPosition.region(
            lockZoneRegion(center: center, radius: controller.lockZoneRadiusMeters)
        )

        if animated {
            withAnimation(.easeInOut(duration: 0.24)) {
                lockZoneMapPosition = position
            }
        } else {
            lockZoneMapPosition = position
        }
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

    private func scheduleLockNameCommit(lockSettingsAfterCommit: Bool = false) {
        if lockSettingsAfterCommit {
            shouldLockSettingsAfterNameCommits = true
        }

        lockNameCommitTask?.cancel()
        lockNameCommitTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }

            lockNameCommitTask = nil
            commitLockNameNow()
            completeSettingsCloseIfReady()
        }
    }

    private func scheduleDeviceDisplayNameCommit(lockSettingsAfterCommit: Bool = false) {
        if lockSettingsAfterCommit {
            shouldLockSettingsAfterNameCommits = true
        }

        deviceDisplayNameCommitTask?.cancel()
        deviceDisplayNameCommitTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }

            deviceDisplayNameCommitTask = nil
            commitDeviceDisplayNameNow()
            completeSettingsCloseIfReady()
        }
    }

    private func cancelPendingLockNameCommit() {
        lockNameCommitTask?.cancel()
        lockNameCommitTask = nil
    }

    private func cancelPendingDeviceDisplayNameCommit() {
        deviceDisplayNameCommitTask?.cancel()
        deviceDisplayNameCommitTask = nil
    }

    private func cancelPendingNameCommits() {
        cancelPendingLockNameCommit()
        cancelPendingDeviceDisplayNameCommit()
        shouldLockSettingsAfterNameCommits = false
    }

    private func commitLockNameNow() {
        let trimmedName = lockNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty {
            lockNameDraft = controller.lockName
            return
        }

        guard trimmedName != controller.lockName else {
            lockNameDraft = controller.lockName
            return
        }

        controller.updateLockName(trimmedName)
        lockNameDraft = controller.lockName
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

    private func completeSettingsCloseIfReady() {
        guard shouldLockSettingsAfterNameCommits,
              lockNameCommitTask == nil,
              deviceDisplayNameCommitTask == nil,
              !isLockNameFocused,
              !isDeviceDisplayNameFocused else {
            return
        }

        shouldLockSettingsAfterNameCommits = false
        controller.lockSettings()
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
        if isLockNameFocused {
            isLockNameFocused = false
            scheduleLockNameCommit(lockSettingsAfterCommit: true)
        } else if isDeviceDisplayNameFocused {
            isDeviceDisplayNameFocused = false
            scheduleDeviceDisplayNameCommit(lockSettingsAfterCommit: true)
        } else if lockNameCommitTask != nil || deviceDisplayNameCommitTask != nil {
            shouldLockSettingsAfterNameCommits = true
            completeSettingsCloseIfReady()
        } else {
            cancelPendingNameCommits()
            lockNameDraft = controller.lockName
            deviceDisplayNameDraft = controller.deviceDisplayName
            controller.lockSettings()
        }

        withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
            settingsExpanded = false
        }
    }
}

private struct LockZoneExpandedMapView: View {
    @ObservedObject var controller: DoorUnlockerController
    let accent: Color

    @Environment(\.dismiss) private var dismiss
    @State private var mapPosition: MapCameraPosition = .automatic
    @State private var directionPulse = false
    @State private var smoothedArrowDegrees = 0.0
    @State private var hasSmoothedArrow = false

    private enum DirectionSource: String {
        case movement
        case compass
        case map
        case unavailable
    }

    private var routeCoordinates: [CLLocationCoordinate2D]? {
        guard let center = controller.lockZoneCenter,
              let userLocation = controller.lockZoneUserLocation else {
            return nil
        }

        return [userLocation, center]
    }

    private var guidance: LockZoneMapGeometry.Guidance? {
        guard let center = controller.lockZoneCenter,
              let userLocation = controller.lockZoneUserLocation else {
            return nil
        }

        return LockZoneMapGeometry.guidance(from: userLocation, to: center)
    }

    private var mapTargetID: String {
        guard let center = controller.lockZoneCenter else { return "none" }
        let userLocation = controller.lockZoneUserLocation
        return [
            String(format: "%.6f", center.latitude),
            String(format: "%.6f", center.longitude),
            String(format: "%.5f", userLocation?.latitude ?? 0),
            String(format: "%.5f", userLocation?.longitude ?? 0),
            String(Int(controller.lockZoneRadiusMeters.rounded()))
        ].joined(separator: ":")
    }

    private var directionSampleID: String {
        [
            directionSource.rawValue,
            String(format: "%.1f", guidance?.bearingDegrees ?? 0),
            String(format: "%.1f", controller.lockZoneCourseDegrees ?? -1),
            String(format: "%.1f", controller.lockZoneHeadingDegrees ?? -1),
            String(controller.lockZoneBluetoothRSSI ?? -999)
        ].joined(separator: ":")
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black
                .ignoresSafeArea()

            if let center = controller.lockZoneCenter {
                Map(
                    position: $mapPosition,
                    interactionModes: [.pan, .zoom]
                ) {
                    MapPolyline(coordinates: LockZoneMapGeometry.ringCoordinates(center: center, radius: controller.lockZoneRadiusMeters))
                        .stroke(accent.opacity(0.28), lineWidth: 12)
                        .mapOverlayLevel(level: .aboveRoads)
                    MapPolyline(coordinates: LockZoneMapGeometry.ringCoordinates(center: center, radius: controller.lockZoneRadiusMeters))
                        .stroke(accent.opacity(0.92), lineWidth: 3)
                        .mapOverlayLevel(level: .aboveRoads)

                    if let routeCoordinates {
                        MapPolyline(coordinates: routeCoordinates)
                            .stroke(accent.opacity(0.74), lineWidth: 4)
                            .mapOverlayLevel(level: .aboveRoads)
                    }

                    Marker(controller.lockName, systemImage: "lock.fill", coordinate: center)
                        .tint(accent)

                    if let userLocation = controller.lockZoneUserLocation {
                        Annotation("You", coordinate: userLocation, anchor: .center) {
                            ZStack {
                                Circle()
                                    .fill(Color.black.opacity(0.62))
                                    .frame(width: 36, height: 36)
                                Circle()
                                    .fill(accent)
                                    .frame(width: 16, height: 16)
                                Circle()
                                    .stroke(accent.opacity(0.72), lineWidth: 3)
                                    .frame(width: 30, height: 30)
                            }
                            .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 5)
                        }
                    }
                }
                .mapControls {
                    MapCompass()
                    MapScaleView()
                }
                .ignoresSafeArea()
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "location.slash.fill")
                        .font(.system(size: 38, weight: .bold))
                        .foregroundStyle(accent)
                    Text("Lock zone not set")
                        .font(.title3.weight(.bold))
                    Text("Unlock once or use current location to set the zone.")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            VStack(spacing: 12) {
                topBar
                directionCue
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            syncMapCamera(animated: false)
            controller.startLockZoneLocationUpdates()
            controller.startLockZoneDirectionUpdates()
            controller.refreshLockZoneLocation()
            updateSmoothedArrow(animated: false)
            directionPulse = true
        }
        .onDisappear {
            controller.stopLockZoneDirectionUpdates()
        }
        .onChange(of: mapTargetID) { _, _ in
            syncMapCamera()
        }
        .onChange(of: directionSampleID) { _, _ in
            updateSmoothedArrow()
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Color.black.opacity(0.66), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close map")

            VStack(alignment: .leading, spacing: 2) {
                Text(controller.lockName)
                    .font(.headline.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text("Lock zone")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button {
                syncMapCamera()
            } label: {
                Image(systemName: "scope")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Color.black.opacity(0.66), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Center map")
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.12))
        }
    }

    private var directionCue: some View {
        HStack(spacing: 12) {
            ZStack {
                if isDirectionArrowActive {
                    Circle()
                        .stroke(accent.opacity(0.28), lineWidth: 2)
                        .frame(width: 58, height: 58)
                        .scaleEffect(directionPulse ? 1.18 : 0.86)
                        .opacity(directionPulse ? 0.12 : 0.62)
                        .animation(.easeInOut(duration: 1.15).repeatForever(autoreverses: false), value: directionPulse)
                }

                Circle()
                    .fill(accent.opacity(0.22))
                    .frame(width: 48, height: 48)

                Image(systemName: directionIconName)
                    .font(.system(size: 21, weight: .black))
                    .foregroundStyle(accent)
                    .rotationEffect(.degrees(isDirectionArrowActive ? smoothedArrowDegrees : 0))
                    .animation(.spring(response: 0.34, dampingFraction: 0.82), value: smoothedArrowDegrees)
            }
            .frame(width: 60, height: 60)

            VStack(alignment: .leading, spacing: 3) {
                Text(guidanceTitle)
                    .font(.subheadline.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Text(guidanceDetail)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.78)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(accent.opacity(0.24), lineWidth: 1)
        }
    }

    private var directionIconName: String {
        if let guidance,
           guidance.distanceMeters <= max(controller.lockZoneRadiusMeters, 5) {
            return "checkmark"
        }

        return guidance == nil ? "location.fill" : "arrow.up"
    }

    private var isDirectionArrowActive: Bool {
        directionIconName == "arrow.up"
    }

    private var isBluetoothNearby: Bool {
        controller.isBluetoothSignalStrongForGuidance
    }

    private var directionSource: DirectionSource {
        guard guidance != nil else { return .unavailable }

        if let speed = controller.lockZoneSpeedMetersPerSecond,
           speed >= 0.8,
           let course = controller.lockZoneCourseDegrees,
           course >= 0,
           let courseAccuracy = controller.lockZoneCourseAccuracyDegrees,
           courseAccuracy <= 55 {
            return .movement
        }

        if let heading = controller.lockZoneHeadingDegrees,
           heading >= 0,
           let headingAccuracy = controller.lockZoneHeadingAccuracyDegrees,
           headingAccuracy <= 40 {
            return .compass
        }

        return .map
    }

    private var rawArrowRotationDegrees: Double {
        guard let guidance else { return 0 }

        switch directionSource {
        case .movement:
            return LockZoneMapGeometry.relativeArrowDegrees(
                targetBearingDegrees: guidance.bearingDegrees,
                phoneHeadingDegrees: controller.lockZoneCourseDegrees ?? guidance.bearingDegrees
            )
        case .compass:
            return LockZoneMapGeometry.relativeArrowDegrees(
                targetBearingDegrees: guidance.bearingDegrees,
                phoneHeadingDegrees: controller.lockZoneHeadingDegrees ?? guidance.bearingDegrees
            )
        case .map:
            return guidance.bearingDegrees
        case .unavailable:
            return 0
        }
    }

    private var guidanceTitle: String {
        guard let guidance else { return "Finding your position" }

        if isBluetoothNearby {
            return "Controller nearby"
        }

        if guidance.distanceMeters <= max(controller.lockZoneRadiusMeters, 5) {
            return "Inside lock zone"
        }

        return "\(controller.formattedDistance(guidance.distanceMeters)) from lock"
    }

    private var guidanceDetail: String {
        guard guidance != nil else {
            return "Keep this screen open while your location updates."
        }

        if isBluetoothNearby {
            return "Bluetooth signal is strong. GPS is no longer the main signal."
        }

        let accuracyText = controller.lockZoneUserAccuracyMeters.map {
            " GPS +/-\(controller.formattedDistance($0))."
        } ?? ""

        switch directionSource {
        case .movement:
            return "Arrow follows your walking direction.\(accuracyText)"
        case .compass:
            return "Arrow follows where your phone is facing.\(accuracyText)"
        case .map:
            return "Compass/course settling. Arrow is map-based.\(accuracyText)"
        case .unavailable:
            return "Keep this screen open while your location updates."
        }
    }

    private func updateSmoothedArrow(animated: Bool = true) {
        let target = rawArrowRotationDegrees
        let nextValue: Double

        if hasSmoothedArrow {
            nextValue = LockZoneMapGeometry.interpolatedDegrees(
                from: smoothedArrowDegrees,
                to: target,
                factor: directionSource == .movement ? 0.42 : 0.28
            )
        } else {
            hasSmoothedArrow = true
            nextValue = target
        }

        if animated {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                smoothedArrowDegrees = nextValue
            }
        } else {
            smoothedArrowDegrees = nextValue
        }
    }

    private func syncMapCamera(animated: Bool = true) {
        guard let center = controller.lockZoneCenter else { return }
        let position = MapCameraPosition.region(
            LockZoneMapGeometry.expandedRegion(
                center: center,
                radius: controller.lockZoneRadiusMeters,
                userLocation: controller.lockZoneUserLocation
            )
        )

        if animated {
            withAnimation(.easeInOut(duration: 0.28)) {
                mapPosition = position
            }
        } else {
            mapPosition = position
        }
    }
}

private enum LockZoneMapGeometry {
    struct Guidance {
        let bearingDegrees: Double
        let distanceMeters: CLLocationDistance
    }

    static func compactRegion(center: CLLocationCoordinate2D, radius: CLLocationDistance) -> MKCoordinateRegion {
        let spanMeters = min(max(radius * 5, 40), 900)
        return MKCoordinateRegion(center: center, latitudinalMeters: spanMeters, longitudinalMeters: spanMeters)
    }

    static func expandedRegion(
        center: CLLocationCoordinate2D,
        radius: CLLocationDistance,
        userLocation: CLLocationCoordinate2D?
    ) -> MKCoordinateRegion {
        guard let userLocation else {
            let spanMeters = min(max(radius * 7, 90), 2_500)
            return MKCoordinateRegion(center: center, latitudinalMeters: spanMeters, longitudinalMeters: spanMeters)
        }

        let distance = distanceMeters(from: userLocation, to: center)
        let latitude = (center.latitude + userLocation.latitude) / 2
        let longitude = (center.longitude + userLocation.longitude) / 2
        let midpoint = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        let spanMeters = min(max(distance * 2.7, radius * 6, 90), 3_500)

        return MKCoordinateRegion(center: midpoint, latitudinalMeters: spanMeters, longitudinalMeters: spanMeters)
    }

    static func ringCoordinates(center: CLLocationCoordinate2D, radius: CLLocationDistance) -> [CLLocationCoordinate2D] {
        guard CLLocationCoordinate2DIsValid(center), radius > 0 else { return [] }

        let earthRadius = 6_371_000.0
        let centerLatitude = center.latitude * .pi / 180
        let centerLongitude = center.longitude * .pi / 180
        let angularDistance = radius / earthRadius

        return (0 ... 96).map { index in
            let bearing = 2 * .pi * Double(index) / 96
            let latitude = asin(
                sin(centerLatitude) * cos(angularDistance) +
                    cos(centerLatitude) * sin(angularDistance) * cos(bearing)
            )
            let longitude = centerLongitude + atan2(
                sin(bearing) * sin(angularDistance) * cos(centerLatitude),
                cos(angularDistance) - sin(centerLatitude) * sin(latitude)
            )

            return CLLocationCoordinate2D(
                latitude: latitude * 180 / .pi,
                longitude: longitude * 180 / .pi
            )
        }
    }

    static func guidance(from userLocation: CLLocationCoordinate2D, to center: CLLocationCoordinate2D) -> Guidance {
        Guidance(
            bearingDegrees: bearingDegrees(from: userLocation, to: center),
            distanceMeters: distanceMeters(from: userLocation, to: center)
        )
    }

    static func relativeArrowDegrees(targetBearingDegrees: Double, phoneHeadingDegrees: Double) -> Double {
        signedDegrees(targetBearingDegrees - phoneHeadingDegrees)
    }

    static func interpolatedDegrees(from current: Double, to target: Double, factor: Double) -> Double {
        current + signedDegrees(target - current) * min(max(factor, 0), 1)
    }

    private static func distanceMeters(from start: CLLocationCoordinate2D, to end: CLLocationCoordinate2D) -> CLLocationDistance {
        CLLocation(latitude: start.latitude, longitude: start.longitude).distance(
            from: CLLocation(latitude: end.latitude, longitude: end.longitude)
        )
    }

    private static func bearingDegrees(from start: CLLocationCoordinate2D, to end: CLLocationCoordinate2D) -> Double {
        let startLatitude = start.latitude * .pi / 180
        let startLongitude = start.longitude * .pi / 180
        let endLatitude = end.latitude * .pi / 180
        let endLongitude = end.longitude * .pi / 180
        let deltaLongitude = endLongitude - startLongitude
        let y = sin(deltaLongitude) * cos(endLatitude)
        let x = cos(startLatitude) * sin(endLatitude) -
            sin(startLatitude) * cos(endLatitude) * cos(deltaLongitude)
        let bearing = atan2(y, x) * 180 / .pi

        return bearing >= 0 ? bearing : bearing + 360
    }

private static func signedDegrees(_ degrees: Double) -> Double {
        let normalized = (degrees + 540).truncatingRemainder(dividingBy: 360) - 180
        return normalized == -180 ? 180 : normalized
    }
}

private struct ThemeSwatchButton: View {
    let theme: DoorAppTheme
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(theme.unlockedColor)
                    Circle()
                        .fill(theme.lockedColor)
                    Circle()
                        .fill(theme.backgroundTail)
                }
                .frame(height: 18)

                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(theme.title)
                            .font(.caption.weight(.bold))
                            .lineLimit(1)
                        Text(theme.subtitle)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }

                    Spacer(minLength: 0)

                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(isSelected ? theme.unlockedColor : .secondary)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(isSelected ? 0.12 : 0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? theme.unlockedColor.opacity(0.62) : Color.white.opacity(0.1), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(theme.title) color scheme")
        .accessibilityValue(isSelected ? "Selected" : theme.subtitle)
    }
}

private struct ScanningStatusPulse: View {
    let accent: Color
    @State private var pulse = false

    var body: some View {
        Circle()
            .stroke(accent.opacity(pulse ? 0.04 : 0.62), lineWidth: 1.8)
            .scaleEffect(pulse ? 1.18 : 0.46)
            .frame(width: 28, height: 28)
            .onAppear {
                pulse = false
                withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) {
                    pulse = true
                }
            }
    }
}

private struct ConnectionStatusAnimation: View {
    let icon: String
    let accent: Color
    let isSearching: Bool
    @State private var pulse = false
    @State private var rotation = 0.0

    var body: some View {
        ZStack {
            if isSearching {
                Circle()
                    .stroke(accent.opacity(pulse ? 0.04 : 0.46), lineWidth: 4)
                    .scaleEffect(pulse ? 1.16 : 0.58)

                Circle()
                    .trim(from: 0.08, to: 0.78)
                    .stroke(
                        Color.white.opacity(0.72),
                        style: StrokeStyle(lineWidth: 5, lineCap: .round)
                    )
                    .rotationEffect(.degrees(rotation))
                    .frame(width: 98, height: 98)
            } else {
                Circle()
                    .strokeBorder(Color.white.opacity(0.22), lineWidth: 4)
                    .frame(width: 98, height: 98)
            }

            Image(systemName: icon)
                .font(.system(size: 48, weight: .bold))
                .foregroundStyle(.white)
                .scaleEffect(isSearching && pulse ? 0.94 : 1.0)
        }
        .frame(width: 118, height: 118)
        .onAppear {
            runAnimation()
        }
        .onChange(of: isSearching) { _, _ in
            runAnimation()
        }
    }

    private func runAnimation() {
        pulse = false
        rotation = 0
        guard isSearching else { return }

        withAnimation(.easeOut(duration: 1.12).repeatForever(autoreverses: false)) {
            pulse = true
        }

        withAnimation(.linear(duration: 1.15).repeatForever(autoreverses: false)) {
            rotation = 360
        }
    }
}

private struct SettingsApplyIcon: View {
    let size: CGFloat
    @State private var rotation = 0.0

    var body: some View {
        Image(systemName: "gearshape.fill")
            .font(.system(size: size, weight: .bold))
            .rotationEffect(.degrees(rotation))
            .onAppear {
                rotation = 0
                withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }
    }
}

private struct SettingsApplyBadge: View {
    let title: String
    let accent: Color
    @State private var rotation = 0.0

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "gearshape.fill")
                .font(.caption2.weight(.bold))
                .rotationEffect(.degrees(rotation))
            Text(title)
                .font(.caption2.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .foregroundStyle(accent)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(accent.opacity(0.16), in: Capsule())
        .overlay {
            Capsule()
                .stroke(accent.opacity(0.24), lineWidth: 1)
        }
        .onAppear {
            rotation = 0
            withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) {
                rotation = 360
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(DoorUnlockerController())
}
