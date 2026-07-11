import DoorUnlockerShared
import SwiftUI

struct LockControlButton: View {
    @ObservedObject var controller: DoorUnlockerController
    let accent: Color
    @State private var motionPhase = false
    @State private var displayedIconIsUnlocked = false
    @State private var iconFlipDegrees = 0.0
    @State private var iconFlipTask: Task<Void, Never>?
    @State private var isUnlockHoldActive = false
    @State private var unlockHoldProgress = 0.0
    @State private var unlockHoldTask: Task<Void, Never>?
    @StateObject private var presentationContinuity = DoorControlPresentationContinuityCoordinator()

    private var statusPresentation: ControllerStatusPresentation {
        ControllerStatusPresentation(controller: controller)
    }

    private var controlPresentation: DoorControlPresentation {
        DoorControlPresentationPolicy.presentation(
            for: DoorControlPresentationInput(
                servoState: controller.servoState,
                isUnlocked: controller.isUnlocked,
                canAcceptDoorCommand: controller.canAcceptDoorCommand,
                isBusy: controller.isBusy,
                isAuthenticatingUnlock: controller.isAuthenticatingUnlock,
                isApplyingControllerSetting: controller.isApplyingControllerSetting,
                isFirmwareUpdateBlockingDoorControl: controller.shouldBlockDoorControlForFirmwareUpdate,
                isDoorCommandQueuedForSecureLink: controller.isDoorCommandQueuedForSecureLink,
                isPreparingKnownController: controller.isDoorControlConnectionTransition,
                preservesDoorControlDuringTransientConnection: presentationContinuity.isRetainingControl,
                isDoorCommandReady: controller.isDoorCommandReady,
                requiresHoldToUnlock: controller.requiresHoldToUnlock,
                isUnlockHoldActive: isUnlockHoldActive,
                activationVerb: .tap,
                controllerSettingApplyTitle: controller.controllerSettingApplyTitle,
                firmwareUpdateActionTitle: controller.firmwareUpdateControlTitle
            )
        )
    }

    private var isApplyingSettingsOnly: Bool {
        controlPresentation.isApplyingSettingsOnly
    }

    private var isFirmwareUpdateOnly: Bool {
        controlPresentation.isFirmwareUpdateOnly
    }

    private var shouldHoldToUnlock: Bool {
        controller.requiresHoldToUnlock && !controller.isUnlocked
    }

    private var shouldShowLockControl: Bool {
        controlPresentation.shouldShowLockControl
    }

    private var primaryPanelTitle: String {
        shouldShowLockControl ? actionTitle : statusPresentation.title
    }

    private var primaryPanelDetail: String? {
        shouldShowLockControl ? nil : statusPresentation.detail
    }

    private var primaryPanelOpacity: Double {
        if isFirmwareUpdateOnly {
            return 1.0
        }

        return shouldShowLockControl && !isPrimaryActionEnabled ? 0.76 : 1.0
    }

    private var isPrimaryActionEnabled: Bool {
        controlPresentation.isPrimaryActionEnabled
    }

    private var actionTitle: String {
        controlPresentation.actionTitle
    }

    var body: some View {
        VStack(spacing: primaryPanelDetail == nil ? 14 : 10) {
            LockControlIcon(
                controller: controller,
                accent: accent,
                statusPresentation: statusPresentation,
                shouldShowLockControl: shouldShowLockControl,
                isApplyingSettingsOnly: isApplyingSettingsOnly,
                isFirmwareUpdateOnly: isFirmwareUpdateOnly,
                displayedIconIsUnlocked: displayedIconIsUnlocked,
                iconFlipDegrees: iconFlipDegrees,
                motionPhase: motionPhase,
                unlockHoldProgress: unlockHoldProgress,
                isUnlockHoldActive: isUnlockHoldActive
            )

            Text(primaryPanelTitle)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.86))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.72)

            if let primaryPanelDetail {
                Text(primaryPanelDetail)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.68))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.78)
                    .padding(.horizontal, 24)
            }
	        }
	        .frame(maxWidth: .infinity)
	        .frame(height: 260)
	        .modifier(LockControlPanelChrome(accent: accent))
	        .shadow(color: accent.opacity(0.28), radius: 24, y: 14)
	        .opacity(primaryPanelOpacity)
	        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .gesture(primaryActionGesture)
        .onAppear {
            displayedIconIsUnlocked = controller.isUnlocked
            presentationContinuity.observe(controller.doorControlPresentationContinuityObservation)
        }
        .onDisappear(perform: cancelTransientAnimation)
        .onChange(of: controller.isChangingState, handleChangingState)
        .onChange(of: controller.servoState, handleServoStateChange)
        .onChange(of: controller.isBusy) { _, isBusy in
            if isBusy { cancelUnlockHold() }
        }
        .onChange(of: controller.doorControlPresentationContinuityObservation) { _, observation in
            presentationContinuity.observe(observation)
        }
        .onChange(of: controller.requiresHoldToUnlock) { _, _ in cancelUnlockHold() }
        .onChange(of: controller.unlockHoldDurationSeconds) { _, _ in cancelUnlockHold() }
        .accessibilityLabel(primaryPanelTitle)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(shouldHoldToUnlock ? "Hold until the ring completes." : "")
	        .accessibilityAction {
	            performPrimaryAction()
	        }
    }

    private var primaryActionGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard isPrimaryActionEnabled, shouldHoldToUnlock else { return }
                beginUnlockHold()
            }
            .onEnded { _ in
                if shouldHoldToUnlock {
                    cancelUnlockHold()
                } else {
                    performPrimaryAction()
                }
            }
    }

    private func handleChangingState(_ oldValue: Bool, _ isChanging: Bool) {
        if isChanging {
            motionPhase = false
            withAnimation(.easeInOut(duration: 0.72).repeatForever(autoreverses: true)) {
                motionPhase = true
            }
        } else {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.72)) {
                motionPhase = false
            }
        }
    }

    private func handleServoStateChange(_ oldValue: String, _ state: String) {
        flipLockIcon(for: state)
        if state == "unlocking" || state == "unlocked" {
            cancelUnlockHold()
        }
    }

    private func performPrimaryAction() {
        guard isPrimaryActionEnabled else { return }
        controller.toggleLock()
    }

    private func beginUnlockHold() {
        guard !isUnlockHoldActive, isPrimaryActionEnabled, shouldHoldToUnlock else { return }
        unlockHoldTask?.cancel()
        isUnlockHoldActive = true
        unlockHoldProgress = 0

        let duration = controller.unlockHoldDurationSeconds
        withAnimation(.linear(duration: duration)) {
            unlockHoldProgress = 1
        }

        unlockHoldTask = Task { @MainActor in
            let nanoseconds = UInt64((duration * 1_000_000_000).rounded())
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            unlockHoldTask = nil
            isUnlockHoldActive = false
            unlockHoldProgress = 0
            guard isPrimaryActionEnabled, shouldHoldToUnlock else { return }
            controller.send(.unlock)
        }
    }

    private func cancelUnlockHold() {
        unlockHoldTask?.cancel()
        unlockHoldTask = nil
        guard isUnlockHoldActive || unlockHoldProgress > 0 else { return }
        isUnlockHoldActive = false
        withAnimation(.easeOut(duration: 0.16)) {
            unlockHoldProgress = 0
        }
    }

    private func flipLockIcon(for state: String) {
        let targetIsUnlocked: Bool
        switch state {
        case "unlocking", "unlocked": targetIsUnlocked = true
        case "locking", "locked": targetIsUnlocked = false
        default: return
        }
        flipLockIcon(isUnlocked: targetIsUnlocked)
    }

    private func flipLockIcon(isUnlocked targetIsUnlocked: Bool) {
        iconFlipTask?.cancel()
        iconFlipTask = nil
        guard displayedIconIsUnlocked != targetIsUnlocked else {
            withAnimation(.easeOut(duration: 0.16)) { iconFlipDegrees = 0 }
            return
        }
        withAnimation(.easeIn(duration: 0.18)) { iconFlipDegrees = 90 }
        iconFlipTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }
            displayedIconIsUnlocked = targetIsUnlocked
            iconFlipDegrees = -90
            withAnimation(.easeOut(duration: 0.22)) { iconFlipDegrees = 0 }
            iconFlipTask = nil
        }
    }

    private func cancelTransientAnimation() {
        cancelUnlockHold()
        iconFlipTask?.cancel()
        iconFlipTask = nil
        presentationContinuity.reset()
    }
}

private struct LockControlPanelChrome: ViewModifier {
    let accent: Color

    func body(content: Content) -> some View {
        content
            .background(panelBackground)
            .overlay(panelBorder)
    }

    private var panelBackground: some View {
        LinearGradient(
            colors: [accent.opacity(0.95), accent.opacity(0.55)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var panelBorder: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(Color.white.opacity(0.22))
    }
}

private struct LockControlIcon: View {
    @ObservedObject var controller: DoorUnlockerController
    let accent: Color
    let statusPresentation: ControllerStatusPresentation
    let shouldShowLockControl: Bool
    let isApplyingSettingsOnly: Bool
    let isFirmwareUpdateOnly: Bool
    let displayedIconIsUnlocked: Bool
    let iconFlipDegrees: Double
    let motionPhase: Bool
    let unlockHoldProgress: Double
    let isUnlockHoldActive: Bool

    var body: some View {
        ZStack {
            Circle().fill(Color.white.opacity(0.12))

            if shouldShowLockControl {
                Circle()
                    .strokeBorder(Color.white.opacity(controller.isChangingState ? 0.34 : 0), lineWidth: 5)
                    .scaleEffect(controller.isChangingState && motionPhase ? 1.2 : 0.9)
                    .opacity(controller.isChangingState && motionPhase ? 0.08 : 0.7)

                Circle()
                    .trim(from: 0.08, to: 0.82)
                    .stroke(Color.white.opacity(controller.isChangingState ? 0.82 : 0), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(controller.isChangingState && motionPhase ? 360 : 0))

                Circle()
                    .trim(from: 0, to: unlockHoldProgress)
                    .stroke(Color.white.opacity(isUnlockHoldActive ? 0.92 : 0), style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))

                Group {
                    if isFirmwareUpdateOnly {
                        FirmwareUpdateSymbolView(
                            state: controller.isFirmwareUpdateSuccessVisible ? .success : .updating,
                            size: 58,
                            tint: .white
                        )
                    } else if isApplyingSettingsOnly {
                        SettingsApplyIcon(size: 58)
                    } else {
                        Image(systemName: displayedIconIsUnlocked ? "lock.open.fill" : "lock.fill")
                            .font(.system(size: 58, weight: .bold))
                            .rotation3DEffect(.degrees(iconFlipDegrees), axis: (x: 0, y: 1, z: 0), perspective: 0.55)
                    }
                }
                .foregroundStyle(.white)
                .scaleEffect((controller.isChangingState && motionPhase) || isUnlockHoldActive ? 0.9 : 1.0)
            } else {
                ConnectionStatusAnimation(
                    icon: statusPresentation.icon,
                    accent: accent,
                    isSearching: statusPresentation.isSearching
                )
            }
        }
        .frame(width: 118, height: 118)
    }
}
