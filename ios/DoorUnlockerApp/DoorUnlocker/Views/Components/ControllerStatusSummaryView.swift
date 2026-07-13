import SwiftUI

struct ControllerStatusSummaryView: View {
    let presentation: ControllerStatusPresentation
    let accent: Color

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                if presentation.isSearching {
                    ScanningStatusPulse(accent: accent)
                }

                Image(systemName: presentation.icon)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(accent)
            }
            .frame(width: 30, height: 30)
            .background(accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(presentation.title)
                    .font(.caption.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                Text(presentation.detail)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
