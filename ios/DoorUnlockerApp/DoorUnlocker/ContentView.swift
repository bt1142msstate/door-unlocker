import SwiftUI

struct ContentView: View {
    @StateObject private var controller = DoorUnlockerController()
    @Environment(\.scenePhase) private var scenePhase
    @State private var motionPhase = false
    @State private var displayedIconIsUnlocked = false
    @State private var iconFlipDegrees = 0.0

    private var accent: Color {
        controller.isUnlocked ? Color(red: 0.35, green: 0.86, blue: 0.58) : Color(red: 0.35, green: 0.72, blue: 1.0)
    }

    private var actionTitle: String {
        if controller.isChangingState {
            return controller.isUnlocked ? "Locking..." : "Unlocking..."
        }

        return controller.isUnlocked ? "Tap to lock" : "Tap to unlock"
    }

    private var modeIcon: String {
        displayedIconIsUnlocked ? "lock.open.fill" : "lock.fill"
    }

    var body: some View {
        ZStack {
            background

            VStack(spacing: 18) {
                header
                stateCard
                Spacer(minLength: 8)
                toggleButton
                Spacer(minLength: 16)
                footerControls
            }
            .padding(20)
        }
        .onChange(of: controller.isChangingState) { _, isChanging in
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
        .onChange(of: controller.servoState) { _, state in
            flipLockIcon(for: state)
        }
        .onAppear {
            displayedIconIsUnlocked = controller.isUnlocked
            controller.performPendingSystemCommand()
        }
        .onOpenURL { url in
            DoorCommandStore.request(from: url)
            controller.performPendingSystemCommand()
        }
        .onReceive(NotificationCenter.default.publisher(for: .doorCommandRequested)) { _ in
            controller.performPendingSystemCommand()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                controller.performPendingSystemCommand()
            }
        }
    }

    private var background: some View {
        ZStack {
            Color(red: 0.03, green: 0.04, blue: 0.05)
            LinearGradient(
                colors: [
                    accent.opacity(0.22),
                    Color(red: 0.03, green: 0.04, blue: 0.05),
                    Color(red: 0.09, green: 0.07, blue: 0.05)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .opacity(0.75)
        }
        .ignoresSafeArea()
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(accent.opacity(0.16))
                Image(systemName: "door.left.hand.closed")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(accent)
            }
            .frame(width: 48, height: 48)

            Text("Door Unlocker")
                .font(.title2.weight(.bold))

            Spacer()
        }
        .padding(.top, 10)
    }

    private var stateCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(controller.stateTitle)
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                    Text(controller.isReady ? "Controller connected" : controller.connectionState)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: controller.isUnlocked ? "lock.open.fill" : "lock.fill")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(accent)
            }

            HStack(spacing: 10) {
                metric(title: "Bluetooth", value: controller.bluetoothState, icon: "dot.radiowaves.left.and.right")
                metric(title: "Link", value: controller.connectionState, icon: "antenna.radiowaves.left.and.right")
            }

            if let error = controller.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.yellow)
                    .lineLimit(2)
            }
        }
        .padding(18)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.12))
        }
    }

    private func metric(title: String, value: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.caption.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(Color.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var toggleButton: some View {
        Button {
            controller.toggleLock()
        } label: {
            VStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.12))

                    Circle()
                        .strokeBorder(Color.white.opacity(controller.isChangingState ? 0.34 : 0), lineWidth: 5)
                        .scaleEffect(controller.isChangingState && motionPhase ? 1.2 : 0.9)
                        .opacity(controller.isChangingState && motionPhase ? 0.08 : 0.7)

                    Circle()
                        .trim(from: 0.08, to: 0.82)
                        .stroke(
                            Color.white.opacity(controller.isChangingState ? 0.82 : 0),
                            style: StrokeStyle(lineWidth: 6, lineCap: .round)
                        )
                        .rotationEffect(.degrees(controller.isChangingState && motionPhase ? 360 : 0))

                    Image(systemName: modeIcon)
                        .font(.system(size: 58, weight: .bold))
                        .foregroundStyle(.white)
                        .rotation3DEffect(
                            .degrees(iconFlipDegrees),
                            axis: (x: 0, y: 1, z: 0),
                            perspective: 0.55
                        )
                        .scaleEffect(controller.isChangingState && motionPhase ? 0.9 : 1.0)
                }
                .frame(width: 118, height: 118)

                Text(actionTitle)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.86))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 260)
            .background(
                LinearGradient(
                    colors: [accent.opacity(0.95), accent.opacity(0.55)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.22))
            }
            .shadow(color: accent.opacity(0.28), radius: 24, y: 14)
            .opacity(controller.isReady && !controller.isChangingState ? 1.0 : 0.55)
        }
        .buttonStyle(.plain)
        .disabled(!controller.isReady || controller.isChangingState)
        .accessibilityLabel(actionTitle)
    }

    private func flipLockIcon(for state: String) {
        let targetIsUnlocked: Bool

        switch state {
        case "unlocking", "unlocked":
            targetIsUnlocked = true
        case "locking", "locked":
            targetIsUnlocked = false
        default:
            return
        }

        guard displayedIconIsUnlocked != targetIsUnlocked else { return }

        withAnimation(.easeIn(duration: 0.18)) {
            iconFlipDegrees = 90
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            displayedIconIsUnlocked = targetIsUnlocked
            iconFlipDegrees = -90

            withAnimation(.easeOut(duration: 0.22)) {
                iconFlipDegrees = 0
            }
        }
    }

    private var footerControls: some View {
        Button {
            controller.scan()
        } label: {
            Label(controller.isReady ? "Refresh Connection" : "Reconnect", systemImage: "antenna.radiowaves.left.and.right")
                .frame(maxWidth: .infinity, minHeight: 50)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }
}

#Preview {
    ContentView()
}
