import SwiftUI

struct ThemeSwatchButton: View {
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
