import SwiftUI

enum FirmwareUpdateVisualState: Equatable {
    case updating
    case success
    case failure
}

struct FirmwareUpdateSymbolView: View {
    let state: FirmwareUpdateVisualState
    let size: CGFloat
    let tint: Color
    @State private var rotation = 0.0
    @State private var successPulse = false

    var body: some View {
        Group {
            switch state {
            case .updating:
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: size, weight: .bold))
                    .rotationEffect(.degrees(rotation))
                    .onAppear(perform: startSpinning)
            case .success:
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: size, weight: .bold))
                    .scaleEffect(successPulse ? 1.08 : 0.92)
                    .opacity(successPulse ? 1 : 0.78)
                    .onAppear(perform: playSuccessPulse)
            case .failure:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: size, weight: .bold))
            }
        }
        .foregroundStyle(tint)
        .onChange(of: state) { _, state in
            switch state {
            case .updating:
                startSpinning()
            case .success:
                playSuccessPulse()
            case .failure:
                rotation = 0
                successPulse = false
            }
        }
    }

    private func startSpinning() {
        successPulse = false
        rotation = 0
        withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) {
            rotation = 360
        }
    }

    private func playSuccessPulse() {
        rotation = 0
        successPulse = false
        withAnimation(.spring(response: 0.34, dampingFraction: 0.58)) {
            successPulse = true
        }
    }
}
