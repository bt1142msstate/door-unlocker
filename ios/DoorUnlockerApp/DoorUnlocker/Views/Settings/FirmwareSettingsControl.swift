import SwiftUI

struct FirmwareSettingsControl: View {
    @ObservedObject var controller: DoorUnlockerController
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(accent)
                Text("Firmware")
                    .font(.caption.weight(.bold))
                Spacer(minLength: 8)
                Text(controller.firmwareVersion)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            Text(controller.bundledFirmwareVersionDisplayText)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            if let progress = controller.firmwareUpdateProgress {
                ProgressView(value: Double(progress), total: 100)
                    .tint(accent)
            }

            Text(controller.firmwareUpdateStatus)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.75)

            if let etaText = controller.firmwareUpdateETAText {
                Text(etaText)
                    .font(.caption2.monospacedDigit().weight(.bold))
                    .foregroundStyle(accent)
                    .lineLimit(1)
            }
        }
        .disabled(controller.isAuthenticatingSettings || controller.isFirmwareUpdateRunning)
        .padding(12)
        .background(Color.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
