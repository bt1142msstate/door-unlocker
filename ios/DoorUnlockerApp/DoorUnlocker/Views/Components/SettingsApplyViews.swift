import SwiftUI

struct SettingsApplyIcon: View {
    let size: CGFloat
    @State private var rotation = 0.0

    var body: some View {
        Image(systemName: "gearshape.fill")
            .font(.system(size: size, weight: .bold))
            .rotationEffect(.degrees(rotation))
            .onAppear {
                rotation = 0
                withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }
    }
}

struct SettingsApplyBadge: View {
    let title: String
    let accent: Color
    @State private var rotation = 0.0

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "gearshape.fill")
                .font(.caption2.weight(.bold))
                .rotationEffect(.degrees(rotation))
            Text(title)
                .font(.caption2.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .foregroundStyle(accent)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(accent.opacity(0.16), in: Capsule())
        .overlay {
            Capsule()
                .stroke(accent.opacity(0.24), lineWidth: 1)
        }
        .onAppear {
            rotation = 0
            withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) {
                rotation = 360
            }
        }
    }
}
