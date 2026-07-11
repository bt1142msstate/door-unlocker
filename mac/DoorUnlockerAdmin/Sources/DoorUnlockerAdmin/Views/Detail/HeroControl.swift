import DoorUnlockerCore
import DoorUnlockerShared
import SwiftUI

struct HeroControl: View {
    @ObservedObject var store: DoorAdminStore
    @State private var isHovering = false
    @State private var displayedIconIsUnlocked = false
    @State private var iconFlipDegrees = 0.0
    @State private var iconFlipTask: Task<Void, Never>?
    @StateObject private var presentationContinuity = DoorControlPresentationContinuityCoordinator()

    private var accent: Color {
        store.status.isUnlocked ? Color(red: 0.35, green: 0.86, blue: 0.58) : Color(red: 0.35, green: 0.72, blue: 1.0)
    }

    private var currentSymbol: String {
        displayedIconIsUnlocked ? "lock.open.fill" : "lock.fill"
    }

    private var controlPresentation: DoorControlPresentation {
        var input = store.doorControlPresentationInput
        input.preservesDoorControlDuringTransientConnection = presentationContinuity.isRetainingControl
        return DoorControlPresentationPolicy.presentation(for: input)
    }

    private var continuityObservation: DoorControlPresentationContinuityObservation {
        DoorControlPresentationContinuityObservation(
            isControlEstablished: store.canSendDoorCommand ||
                store.isDoorCommandQueued || store.isChangingDoorState,
            isTransientConnection: store.sessionAssessment.phase.isKnownControllerConnectionInProgress
        )
    }

    private var actionTitle: String {
        controlPresentation.actionTitle
    }

    private var stateTitle: String {
        store.stateTitle
    }

    private var isApplyingSettingsOnly: Bool {
        controlPresentation.isApplyingSettingsOnly
    }

    private var targetIconIsUnlocked: Bool {
        switch store.status.bleState {
        case "unlocking", "unlocked":
            return true
        case "locking", "locked":
            return false
        default:
            return store.status.isUnlocked
        }
    }

    private var supportingText: String? {
        if store.isBusy {
            return store.message
        }

        if store.status.hasPendingRequest {
            return "Approve or reject the waiting device below."
        }

        let redundantMessages = [
            "Door locked",
            "Door unlocked",
            "Controller ready",
            "Disconnected"
        ]

        if redundantMessages.contains(store.message) {
            return nil
        }

        return store.message
    }

    var body: some View {
        HStack(spacing: 22) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(stateTitle)
                        .font(.system(size: 46, weight: .semibold, design: .rounded))
                        .contentTransition(.numericText())

                    if let countdownText = store.status.autoLockCountdownText {
                        Label(countdownText, systemImage: "timer")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(accent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .contentTransition(.numericText())
                    }
                }

                ControllerStatusStrip(store: store, tint: accent)

                if let supportingText {
                    Text(supportingText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                if let error = store.visibleLastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.yellow)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 16)

            Button {
                store.toggleLock()
            } label: {
                ZStack {
                    Circle()
                        .fill(accent.opacity(store.canSendDoorCommand ? 0.16 : 0.08))
                        .overlay {
                            Circle()
                                .stroke(accent.opacity(store.canSendDoorCommand ? 0.28 : 0.12), lineWidth: 1)
                        }
                        .shadow(color: accent.opacity(isHovering && store.canSendDoorCommand ? 0.24 : 0.08), radius: isHovering ? 18 : 10)

                    Circle()
                        .trim(from: 0.08, to: 0.82)
                        .stroke(
                            accent.opacity(store.isChangingDoorState ? 0.75 : 0),
                            style: StrokeStyle(lineWidth: 5, lineCap: .round)
                        )
                        .rotationEffect(.degrees(store.isChangingDoorState ? 360 : 0))
                        .animation(
                            store.isChangingDoorState ? .linear(duration: 1.0).repeatForever(autoreverses: false) : .default,
                            value: store.isChangingDoorState
                        )

                    VStack(spacing: 11) {
                        if isApplyingSettingsOnly {
                            SettingsApplyIcon(size: 46)
                        } else {
                            Image(systemName: currentSymbol)
                                .font(.system(size: 46, weight: .semibold))
                                .symbolRenderingMode(.hierarchical)
                                .rotation3DEffect(
                                    .degrees(iconFlipDegrees),
                                    axis: (x: 0, y: 1, z: 0),
                                    perspective: 0.55
                                )
                        }
                        Text(actionTitle)
                            .font(.title3.weight(.semibold))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .minimumScaleFactor(0.72)
                    }
                    .foregroundStyle(store.canSendDoorCommand ? accent : .secondary)
                }
                .frame(width: 158, height: 158)
                .scaleEffect(isHovering && store.canSendDoorCommand ? 1.035 : 1)
                .animation(.spring(response: 0.26, dampingFraction: 0.78), value: isHovering)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!controlPresentation.isPrimaryActionEnabled)
            .onHover { isHovering = $0 }
        }
        .animation(.spring(response: 0.26, dampingFraction: 0.78), value: store.isApplyingControllerSetting)
        .animation(.spring(response: 0.26, dampingFraction: 0.78), value: store.isDoorCommandQueued)
        .onAppear {
            displayedIconIsUnlocked = targetIconIsUnlocked
            presentationContinuity.observe(continuityObservation)
        }
        .onChange(of: store.status.bleState) { _, state in
            flipLockIcon(for: state)
        }
        .onChange(of: store.status.isUnlocked) { _, _ in
            flipLockIcon(isUnlocked: targetIconIsUnlocked)
        }
        .onChange(of: continuityObservation) { _, observation in
            presentationContinuity.observe(observation)
        }
        .onDisappear {
            iconFlipTask?.cancel()
            iconFlipTask = nil
            presentationContinuity.reset()
        }
        .padding(24)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.regularMaterial)
                .overlay(alignment: .topLeading) {
                    LinearGradient(
                        colors: [accent.opacity(0.16), .clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(accent.opacity(0.16), lineWidth: 1)
        }
    }

    private func flipLockIcon(for state: String) {
        switch state {
        case "unlocking", "unlocked":
            flipLockIcon(isUnlocked: true)
        case "locking", "locked":
            flipLockIcon(isUnlocked: false)
        default:
            break
        }
    }

    private func flipLockIcon(isUnlocked targetIsUnlocked: Bool) {
        iconFlipTask?.cancel()
        iconFlipTask = nil

        guard displayedIconIsUnlocked != targetIsUnlocked else {
            withAnimation(.easeOut(duration: 0.16)) {
                iconFlipDegrees = 0
            }
            return
        }

        withAnimation(.easeIn(duration: 0.18)) {
            iconFlipDegrees = 90
        }

        iconFlipTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }

            displayedIconIsUnlocked = targetIsUnlocked
            iconFlipDegrees = -90

            withAnimation(.easeOut(duration: 0.22)) {
                iconFlipDegrees = 0
            }

            iconFlipTask = nil
        }
    }
}
