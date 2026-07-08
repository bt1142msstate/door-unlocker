import SwiftUI

struct ControllerSettingsView: View {
    @ObservedObject var controller: DoorUnlockerController
    let accent: Color
    @Binding var appThemeRawValue: String
    @Binding var settingsExpanded: Bool
    @Binding var isLockZoneMapExpanded: Bool
    @Binding var isFirmwareImporterPresented: Bool

    private var appTheme: DoorAppTheme {
        DoorAppTheme(rawValue: appThemeRawValue) ?? .original
    }

    private var settingsDisclosureActionText: String {
        controller.isAuthenticatingSettings ? "Opening" : settingsExpanded ? "Hide" : "Show"
    }

    var body: some View {
        DisclosureGroup(isExpanded: Binding(get: { settingsExpanded }, set: setExpanded)) {
            VStack(spacing: 10) {
                LockNameControl(controller: controller, accent: accent)
                AppearanceThemeControl(appTheme: appTheme, appThemeRawValue: $appThemeRawValue, accent: accent)
                UnlockGestureControl(controller: controller, accent: accent)
                UnlockAuthenticationToggle(controller: controller, accent: accent)
                ProximityUnlockToggle(controller: controller, accent: accent)
                LockZoneSettingsCard(
                    controller: controller,
                    accent: accent,
                    isLockZoneMapExpanded: $isLockZoneMapExpanded
                )
                UnlockNotificationsToggle(controller: controller, accent: accent)
                DeviceDisplayNameControl(controller: controller, accent: accent)
                AutoLockTimeoutControl(controller: controller, accent: accent)
                ServoAnglesControl(controller: controller, accent: accent)
                FirmwareSettingsControl(
                    controller: controller,
                    accent: accent,
                    isFirmwareImporterPresented: $isFirmwareImporterPresented
                )
                StartupTelemetryControl(controller: controller, accent: accent)
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

    private func setExpanded(_ wantsExpanded: Bool) {
        if wantsExpanded {
            openSettings()
        } else {
            closeSettings()
        }
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
        withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
            settingsExpanded = false
        }

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(160))
            controller.lockSettings()
        }
    }
}
