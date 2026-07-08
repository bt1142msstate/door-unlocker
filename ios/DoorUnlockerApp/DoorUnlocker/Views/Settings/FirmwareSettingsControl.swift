import SwiftUI

struct FirmwareSettingsControl: View {
    @ObservedObject var controller: DoorUnlockerController
    let accent: Color
    @Binding var isFirmwareImporterPresented: Bool

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

            if let progress = controller.firmwareUpdateProgress {
                ProgressView(value: Double(progress), total: 100)
                    .tint(accent)
            }

            Text(controller.firmwareUpdateStatus)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.75)

            HStack(spacing: 8) {
                if controller.bundledFirmwarePackageURL != nil {
                    Button {
                        controller.startBundledFirmwareUpdate()
                    } label: {
                        Label("Install Bundled Update", systemImage: "shippingbox.fill")
                            .frame(maxWidth: .infinity, minHeight: 38)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(accent)
                }

                Button {
                    isFirmwareImporterPresented = true
                } label: {
                    Label("Choose ZIP", systemImage: "doc.zipper")
                        .frame(maxWidth: .infinity, minHeight: 38)
                }
                .buttonStyle(.bordered)
                .tint(accent)
            }
            .font(.caption.weight(.bold))
        }
        .disabled(controller.isAuthenticatingSettings || controller.isFirmwareUpdateRunning)
        .padding(12)
        .background(Color.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
