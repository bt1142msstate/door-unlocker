import SwiftUI

struct ProximityUnlockToggle: View {
    @ObservedObject var controller: DoorUnlockerController
    let accent: Color

    var body: some View {
        Toggle(isOn: Binding(
            get: { controller.proximityUnlockEnabled },
            set: { controller.setProximityUnlockEnabled($0) }
        )) {
            HStack(spacing: 8) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .foregroundStyle(accent)
                Text("Proximity Unlock")
                    .font(.caption.weight(.bold))
                Spacer(minLength: 8)
                Text(controller.proximityUnlockStatus)
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

struct AutoLockTimeoutControl: View {
    @ObservedObject var controller: DoorUnlockerController
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "timer")
                    .foregroundStyle(accent)
                Text("Auto-lock")
                    .font(.caption.weight(.bold))
                Spacer(minLength: 8)
                Text("\(controller.autoLockSeconds)s")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }

            Text("Lock after \(controller.autoLockSeconds) seconds")
                .font(.callout.weight(.semibold))
                .contentTransition(.numericText())

            Slider(
                value: Binding(
                    get: { Double(controller.autoLockSeconds) },
                    set: { controller.updateAutoLockSeconds(Int($0.rounded())) }
                ),
                in: Double(controller.autoLockRange.lowerBound) ... Double(controller.autoLockRange.upperBound),
                step: 5,
                onEditingChanged: { isEditing in
                    if !isEditing {
                        controller.commitAutoLockSeconds()
                    }
                }
            )
            .tint(accent)

            HStack {
                Text("\(controller.autoLockRange.lowerBound)s")
                Spacer()
                Text("\(controller.autoLockRange.upperBound)s")
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)

            Text(controller.autoLockStatus)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .disabled(controller.isAuthenticatingSettings)
        .padding(12)
        .background(Color.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct ServoAnglesControl: View {
    @ObservedObject var controller: DoorUnlockerController
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "dial.low")
                    .foregroundStyle(accent)
                Text("Servo Angles")
                    .font(.caption.weight(.bold))
                Spacer(minLength: 8)
                Text("\(controller.servoLockAngle)° / \(controller.servoUnlockAngle)°")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }

            ServoAngleSlider(
                title: "Rest angle",
                value: controller.servoLockAngle,
                range: controller.servoAngleRange,
                accent: accent,
                setValue: controller.updateServoLockAngle,
                commitValue: controller.commitServoAngles
            )

            ServoAngleSlider(
                title: "Push angle",
                value: controller.servoUnlockAngle,
                range: controller.servoAngleRange,
                accent: accent,
                setValue: controller.updateServoUnlockAngle,
                commitValue: controller.commitServoAngles
            )

            if !controller.servoAnglesAreAtDefaults {
                Button {
                    controller.resetServoAnglesToDefaults()
                } label: {
                    Label("Reset to Defaults", systemImage: "arrow.counterclockwise")
                        .font(.caption.weight(.bold))
                        .frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.bordered)
                .tint(accent)
            }

            Text("\(controller.servoAnglesStatus) - safe range \(controller.servoAngleRange.lowerBound)°-\(controller.servoAngleRange.upperBound)°")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
        }
        .disabled(controller.isAuthenticatingSettings)
        .padding(12)
        .background(Color.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct ServoAngleSlider: View {
    let title: String
    let value: Int
    let range: ClosedRange<Int>
    let accent: Color
    let setValue: (Int) -> Void
    let commitValue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.caption.weight(.bold))
                Spacer(minLength: 8)
                Text("\(value)°")
                    .font(.caption2.monospacedDigit().weight(.bold))
                    .foregroundStyle(.secondary)
            }

            Slider(
                value: Binding(
                    get: { Double(value) },
                    set: { setValue(Int($0.rounded())) }
                ),
                in: Double(range.lowerBound) ... Double(range.upperBound),
                step: 1,
                onEditingChanged: { isEditing in
                    if !isEditing {
                        commitValue()
                    }
                }
            )
            .tint(accent)
        }
    }
}
