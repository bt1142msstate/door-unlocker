import SwiftUI

struct UnlockGestureControl: View {
    @ObservedObject var controller: DoorUnlockerController
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "hand.tap.fill")
                    .foregroundStyle(accent)
                Text("Unlock Gesture")
                    .font(.caption.weight(.bold))
                Spacer(minLength: 8)
                Text(controller.requiresHoldToUnlock ? "Hold" : "Tap")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }

            Picker("Unlock Gesture", selection: Binding(
                get: { controller.requiresHoldToUnlock },
                set: { controller.setRequiresHoldToUnlock($0) }
            )) {
                Text("Tap").tag(false)
                Text("Hold").tag(true)
            }
            .pickerStyle(.segmented)

            if controller.requiresHoldToUnlock {
                Stepper(
                    value: Binding(
                        get: { controller.unlockHoldDurationSeconds },
                        set: { controller.updateUnlockHoldDurationSeconds($0) }
                    ),
                    in: controller.unlockHoldDurationRange,
                    step: 0.25
                ) {
                    HStack(spacing: 8) {
                        Image(systemName: "timer")
                            .foregroundStyle(accent)
                        Text("Hold Time")
                            .font(.caption.weight(.bold))
                        Spacer(minLength: 8)
                        Text(Self.formattedDuration(controller.unlockHoldDurationSeconds))
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .disabled(controller.isAuthenticatingSettings)
        .padding(12)
        .background(Color.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private static func formattedDuration(_ seconds: Double) -> String {
        if abs(seconds.rounded() - seconds) < 0.001 {
            return "\(Int(seconds))s"
        }

        let tenths = (seconds * 10).rounded() / 10
        return abs(tenths - seconds) < 0.001
            ? String(format: "%.1fs", seconds)
            : String(format: "%.2fs", seconds)
    }
}

struct UnlockAuthenticationToggle: View {
    @ObservedObject var controller: DoorUnlockerController
    let accent: Color

    var body: some View {
        Toggle(isOn: Binding(
            get: { controller.requiresUnlockAuthentication },
            set: { controller.setRequiresUnlockAuthentication($0) }
        )) {
            HStack(spacing: 8) {
                Image(systemName: "faceid")
                    .foregroundStyle(accent)
                Text("Face ID / Passcode")
                    .font(.caption.weight(.bold))
                Spacer(minLength: 8)
                Text(controller.requiresUnlockAuthentication ? "On" : "Off")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
        .tint(accent)
        .disabled(controller.isAuthenticatingSettings)
        .padding(12)
        .background(Color.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct UnlockNotificationsToggle: View {
    @ObservedObject var controller: DoorUnlockerController
    let accent: Color

    var body: some View {
        Toggle(isOn: Binding(
            get: { controller.unlockNotificationsEnabled },
            set: { controller.setUnlockNotificationsEnabled($0) }
        )) {
            HStack(spacing: 8) {
                Image(systemName: "bell.badge.fill")
                    .foregroundStyle(accent)
                Text("Unlock Notifications")
                    .font(.caption.weight(.bold))
                Spacer(minLength: 8)
                Text(controller.unlockNotificationStatus)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .toggleStyle(.switch)
        .tint(accent)
        .disabled(controller.isAuthenticatingSettings)
        .padding(12)
        .background(Color.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
