import SwiftUI

struct ControllerStateCard: View {
    @ObservedObject var controller: DoorUnlockerController
    let accent: Color
    @Binding var appThemeRawValue: String
    @Binding var settingsExpanded: Bool
    @Binding var isLockZoneMapExpanded: Bool
    @State private var isInviteSheetPresented = false

    private var statusPresentation: ControllerStatusPresentation {
        ControllerStatusPresentation(controller: controller)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            header
            ControllerStatusSummaryView(presentation: statusPresentation, accent: accent)

            if controller.shouldShowFirmwareUpdateBanner {
                FirmwareUpdateStatusBanner(
                    visualState: firmwareUpdateVisualState,
                    title: firmwareUpdateTitle,
                    status: controller.firmwareUpdateDeviceText ?? controller.firmwareUpdateStatus,
                    progress: controller.displayedFirmwareUpdateProgress,
                    etaText: controller.firmwareUpdateETAText,
                    accent: accent
                )
            }

            ControllerSettingsView(
                controller: controller,
                accent: accent,
                appThemeRawValue: $appThemeRawValue,
                settingsExpanded: $settingsExpanded,
                isLockZoneMapExpanded: $isLockZoneMapExpanded
            )

            PairingGuidanceView(
                controller: controller,
                accent: accent,
                isInviteSheetPresented: $isInviteSheetPresented
            )

            if let error = controller.visibleLastError {
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
        .sheet(isPresented: $isInviteSheetPresented) {
            DeviceInviteSheet(controller: controller, accent: accent)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    private var header: some View {
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
                    CountdownBadgeView(text: countdownText, accent: accent)
                }
            }

            Spacer()
            FirmwareVersionBadge(text: controller.firmwareVersionDisplayText, accent: accent)
        }
    }

    private var firmwareUpdateVisualState: FirmwareUpdateVisualState {
        if controller.isFirmwareUpdateFailureVisible {
            return .failure
        }

        if controller.isFirmwareUpdateSuccessVisible {
            return .success
        }

        return .updating
    }

    private var firmwareUpdateTitle: String {
        switch firmwareUpdateVisualState {
        case .updating:
            return controller.isFirmwareUpdateVerifying ? "Verifying firmware" : "Updating controller"
        case .success:
            return "Firmware updated"
        case .failure:
            return "Firmware update failed"
        }
    }
}
