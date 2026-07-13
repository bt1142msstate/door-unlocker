import SwiftUI

struct DoorUnlockerScreen: View {
    @EnvironmentObject private var controller: DoorUnlockerController
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("DoorUnlockerAppTheme") private var appThemeRawValue = DoorAppTheme.original.rawValue
    @State private var settingsExpanded = false
    @State private var isLockZoneMapExpanded = false
    @State private var lastForegroundControllerRefreshAt = Date.distantPast

    private var appTheme: DoorAppTheme {
        DoorAppTheme(rawValue: appThemeRawValue) ?? .original
    }

    private var accent: Color {
        appTheme.accent(isUnlocked: controller.isUnlocked)
    }

    var body: some View {
        ZStack {
            DoorUnlockerBackground(accent: accent, tail: appTheme.backgroundTail)

            GeometryReader { proxy in
                ScrollView {
                    DoorMainContentView(
                        controller: controller,
                        accent: accent,
                        appThemeRawValue: $appThemeRawValue,
                        settingsExpanded: $settingsExpanded,
                        isLockZoneMapExpanded: $isLockZoneMapExpanded
                    )
                    .frame(minHeight: proxy.size.height, alignment: .top)
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollDismissesKeyboard(.interactively)
            }
        }
        .onAppear(perform: appear)
        .onOpenURL(perform: handleOpenURL)
        .onReceive(NotificationCenter.default.publisher(for: .doorCommandRequested)) { _ in
            controller.performPendingSystemCommand()
        }
        .fullScreenCover(isPresented: $isLockZoneMapExpanded) {
            LockZoneExpandedMapView(controller: controller, accent: accent)
        }
        .onChange(of: scenePhase, handleScenePhaseChange)
        .onChange(of: controller.areSettingsUnlocked) { _, isUnlocked in
            withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                settingsExpanded = isUnlocked
            }
        }
    }

    private func appear() {
        refreshForegroundController()
    }

    private func handleOpenURL(_ url: URL) {
#if DEBUG
        if url.scheme == "doorunlocker", url.host == "debug-install-bundled-firmware" {
            controller.startBundledFirmwareUpdateForTesting()
            return
        }
        if url.scheme == "doorunlocker", url.host == "debug-lock" {
            _ = controller.send(.lock)
            return
        }
        if url.scheme == "doorunlocker", url.host == "debug-unlock" {
            _ = controller.send(.unlock)
            return
        }
        if url.scheme == "doorunlocker", url.host == "debug-timeout",
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let rawSeconds = components.queryItems?.first(where: { $0.name == "seconds" })?.value,
           let seconds = Int(rawSeconds) {
            controller.applyAutoLockTimeoutForTesting(seconds)
            return
        }
#endif
        if controller.handlePairingInviteURL(url) {
            settingsExpanded = false
            return
        }

        DoorCommandStore.request(from: url)
        controller.performPendingSystemCommand()
    }

    private func handleScenePhaseChange(_ oldPhase: ScenePhase, _ phase: ScenePhase) {
        if phase == .active {
            controller.recordWarmLaunchActivation()
            controller.cancelForceQuitReliabilityWarning()
            refreshForegroundController()
            controller.refreshNotificationSettings()
        } else if SettingsSceneSecurityPolicy.shouldLockSettings(for: phase) {
            isLockZoneMapExpanded = false
            controller.prepareForceQuitReliabilityWarningIfNeeded()
            closeSettings()
        }
    }

    private func refreshForegroundController() {
        let now = Date()
        if now.timeIntervalSince(lastForegroundControllerRefreshAt) >= 0.5 {
            lastForegroundControllerRefreshAt = now
            controller.refreshStateFromController()
        }

        controller.performPendingSystemCommand()
    }

	    private func closeSettings() {
	        withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
	            settingsExpanded = false
	        }
	
	        Task { @MainActor in
	            try? await Task.sleep(for: .milliseconds(160))
	            controller.lockSettings()
	        }
	    }
	}

private struct DoorUnlockerBackground: View {
    let accent: Color
    let tail: Color

    var body: some View {
        ZStack {
            Color(red: 0.03, green: 0.04, blue: 0.05)
            LinearGradient(
                colors: [
                    accent.opacity(0.22),
                    Color(red: 0.03, green: 0.04, blue: 0.05),
                    tail
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .opacity(0.75)
        }
        .ignoresSafeArea()
    }
}

private struct DoorMainContentView: View {
    @ObservedObject var controller: DoorUnlockerController
    let accent: Color
    @Binding var appThemeRawValue: String
    @Binding var settingsExpanded: Bool
    @Binding var isLockZoneMapExpanded: Bool

    var body: some View {
        VStack(spacing: settingsExpanded ? 12 : 18) {
            DoorHeaderView(lockName: controller.lockName)
            .padding(.top, 10)

            ControllerStateCard(
                controller: controller,
                accent: accent,
                appThemeRawValue: $appThemeRawValue,
                settingsExpanded: $settingsExpanded,
                isLockZoneMapExpanded: $isLockZoneMapExpanded
            )

            if settingsExpanded {
                Spacer(minLength: 0)
            } else {
                Spacer(minLength: 8)
                LockControlButton(controller: controller, accent: accent)
                    .transition(
                        .asymmetric(
                            insertion: .scale(scale: 0.94).combined(with: .opacity),
                            removal: .scale(scale: 0.88).combined(with: .opacity)
                        )
                    )
                Spacer(minLength: 16)
            }

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
        .padding(20)
        .animation(.spring(response: 0.32, dampingFraction: 0.78), value: settingsExpanded)
    }
}
