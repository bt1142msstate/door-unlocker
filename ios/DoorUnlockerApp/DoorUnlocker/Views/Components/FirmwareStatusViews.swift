import SwiftUI

struct FirmwareVersionBadge: View {
    let text: String
    let accent: Color

    var body: some View {
        Label(text, systemImage: "cpu.fill")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white.opacity(0.86))
            .lineLimit(1)
            .minimumScaleFactor(0.68)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(accent.opacity(0.16), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(accent.opacity(0.22))
            }
            .accessibilityLabel(text)
    }
}

struct FirmwareUpdateStatusBanner: View {
    let visualState: FirmwareUpdateVisualState
    let title: String
    let status: String
    let progress: Int?
    let accent: Color

    private var shouldShowProgress: Bool {
        visualState == .updating && progress != nil
    }

    var body: some View {
        HStack(spacing: 10) {
            FirmwareUpdateSymbolView(state: visualState, size: 16, tint: accent)
                .frame(width: 28, height: 28)
                .background(accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.caption.weight(.bold))

                Text(status)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)

                if shouldShowProgress, let progress {
                    ProgressView(value: Double(progress), total: 100)
                        .tint(accent)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
