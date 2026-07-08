import SwiftUI

struct StartupTelemetryControl: View {
    @ObservedObject var controller: DoorUnlockerController
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.path.ecg")
                    .foregroundStyle(accent)
                Text("Startup Trace")
                    .font(.caption.weight(.bold))
                Spacer(minLength: 8)
                Text("\(controller.startupTelemetryEntries.count) events")
                    .font(.caption2.monospacedDigit().weight(.bold))
                    .foregroundStyle(.secondary)
            }

            if controller.startupTelemetryEntries.isEmpty {
                Text("No startup events recorded yet.")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(controller.startupTelemetryEntries) { entry in
                        StartupTelemetryRow(entry: entry, accent: accent)
                    }
                }
                .padding(10)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .padding(12)
        .background(Color.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct StartupTelemetryRow: View {
    let entry: DoorUnlockerController.StartupTelemetryEntry
    let accent: Color

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(entry.timeText)
                .font(.caption2.monospacedDigit().weight(.bold))
                .foregroundStyle(accent)
                .frame(width: 58, alignment: .trailing)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.primary)

                if let details = entry.details {
                    Text(details)
                        .font(.caption2.monospaced().weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.72)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
