import SwiftUI

struct SettingsApplyIcon: View {
    let size: CGFloat
    @State private var rotation = 0.0

    var body: some View {
        Image(systemName: "gearshape.fill")
            .font(.system(size: size, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .rotationEffect(.degrees(rotation))
            .onAppear {
                rotation = 0
                withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }
    }
}
