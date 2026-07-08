import SwiftUI

struct ScanningStatusPulse: View {
    let accent: Color
    @State private var pulse = false

    var body: some View {
        Circle()
            .stroke(accent.opacity(pulse ? 0.04 : 0.62), lineWidth: 1.8)
            .scaleEffect(pulse ? 1.18 : 0.46)
            .frame(width: 28, height: 28)
            .onAppear {
                pulse = false
                withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) {
                    pulse = true
                }
            }
    }
}

struct ConnectionStatusAnimation: View {
    let icon: String
    let accent: Color
    let isSearching: Bool
    @State private var pulse = false
    @State private var rotation = 0.0

    var body: some View {
        ZStack {
            if isSearching {
                Circle()
                    .stroke(accent.opacity(pulse ? 0.04 : 0.46), lineWidth: 4)
                    .scaleEffect(pulse ? 1.16 : 0.58)

                Circle()
                    .trim(from: 0.08, to: 0.78)
                    .stroke(
                        Color.white.opacity(0.72),
                        style: StrokeStyle(lineWidth: 5, lineCap: .round)
                    )
                    .rotationEffect(.degrees(rotation))
                    .frame(width: 98, height: 98)
            } else {
                Circle()
                    .strokeBorder(Color.white.opacity(0.22), lineWidth: 4)
                    .frame(width: 98, height: 98)
            }

            Image(systemName: icon)
                .font(.system(size: 48, weight: .bold))
                .foregroundStyle(.white)
                .scaleEffect(isSearching && pulse ? 0.94 : 1.0)
        }
        .frame(width: 118, height: 118)
        .onAppear {
            runAnimation()
        }
        .onChange(of: isSearching) { _, _ in
            runAnimation()
        }
    }

    private func runAnimation() {
        pulse = false
        rotation = 0
        guard isSearching else { return }

        withAnimation(.easeOut(duration: 1.12).repeatForever(autoreverses: false)) {
            pulse = true
        }

        withAnimation(.linear(duration: 1.15).repeatForever(autoreverses: false)) {
            rotation = 360
        }
    }
}
