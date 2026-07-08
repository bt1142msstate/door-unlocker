import SwiftUI

struct CountdownBadgeView: View {
    let text: String
    let accent: Color

    var body: some View {
        Label(text, systemImage: "timer")
            .font(.caption.weight(.bold))
            .lineLimit(1)
            .minimumScaleFactor(0.78)
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(accent.opacity(0.24), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(accent.opacity(0.28))
            }
    }
}
