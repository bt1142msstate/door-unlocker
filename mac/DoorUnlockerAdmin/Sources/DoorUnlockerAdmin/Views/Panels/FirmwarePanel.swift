import DoorUnlockerCore
import SwiftUI

struct FirmwarePanel: View {
    @ObservedObject var store: DoorAdminStore

    private var accent: Color {
        store.status.isUnlocked ? Color(red: 0.35, green: 0.86, blue: 0.58) : Color(red: 0.35, green: 0.72, blue: 1.0)
    }

    var body: some View {
        PanelSurface {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Label("Firmware", systemImage: "arrow.triangle.2.circlepath")
                        .font(.headline)
                    Spacer()
                    Text(store.status.firmwareVersion)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(store.firmwareUpdateStatus)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)

                    if let progress = store.firmwareUpdateProgress {
                        ProgressView(value: Double(progress), total: 100)
                            .tint(accent)
                    }
                }
            }
        }
    }
}
