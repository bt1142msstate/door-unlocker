import SwiftUI

struct HandoffView: View {
    @StateObject var coordinator: HandoffCoordinator

    private var accent: Color {
        Color(nsColor: coordinator.request.accent.color)
    }

    private var isCompleting: Bool {
        coordinator.phase == .completing
    }

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                Spacer(minLength: 20)
                actionVisual
                message
                Spacer(minLength: 24)
                controls
            }
            .padding(30)
        }
        .frame(width: 500, height: 440)
        .task { coordinator.begin() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(accent)
                .frame(width: 8, height: 8)
            Text("DOOR UNLOCKER TEST ASSISTANT")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Circle()
                .fill(accent)
                .frame(width: 8, height: 8)
                .shadow(color: accent.opacity(0.55), radius: 5)
        }
    }

    @ViewBuilder
    private var actionVisual: some View {
        ZStack {
            Circle()
                .fill(accent.opacity(0.12))
                .frame(width: 116, height: 116)
            Circle()
                .stroke(accent.opacity(0.34), lineWidth: 1)
                .frame(width: 116, height: 116)

            switch coordinator.phase {
            case .counting(let value):
                Text(String(value))
                    .font(.system(size: 56, weight: .bold, design: .rounded))
                    .contentTransition(.numericText())
                    .foregroundStyle(accent)
            case .completing:
                Image(systemName: "checkmark")
                    .font(.system(size: 46, weight: .bold))
                    .foregroundStyle(accent)
                    .transition(.scale.combined(with: .opacity))
            default:
                Image(systemName: coordinator.request.symbol)
                    .font(.system(size: 46, weight: .semibold))
                    .foregroundStyle(accent)
            }
        }
        .animation(.snappy(duration: 0.28), value: coordinator.phase)
    }

    private var message: some View {
        VStack(spacing: 10) {
            Text(isCompleting ? "Handoff complete" : coordinator.request.title)
                .font(.system(size: 24, weight: .bold))
                .multilineTextAlignment(.center)

            Text(messageText)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 390)
        }
        .padding(.top, 22)
    }

    private var messageText: String {
        switch coordinator.phase {
        case .ready:
            coordinator.request.instruction
        case .counting:
            "Follow the spoken instruction when the countdown finishes."
        case .awaitingConfirmation:
            coordinator.request.confirmation
        case .completing:
            "The waiting test is continuing automatically."
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button("Cancel") { coordinator.cancel() }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .focusable(false)
                .disabled(isCompleting)

            Button(action: coordinator.performPrimaryAction) {
                HStack(spacing: 8) {
                    Text(coordinator.primaryLabel)
                    if !isCompleting {
                        Image(systemName: "arrow.right")
                    }
                }
                .frame(minWidth: 150)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(accent)
            .disabled(!coordinator.primaryEnabled)
            .keyboardShortcut(.defaultAction)
        }
    }
}
