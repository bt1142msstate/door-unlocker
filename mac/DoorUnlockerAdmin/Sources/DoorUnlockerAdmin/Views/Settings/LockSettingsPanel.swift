import DoorUnlockerCore
import SwiftUI

struct LockSettingsPanel: View {
    @ObservedObject var store: DoorAdminStore
    @State private var lockNameDraft = ""
    @State private var isLockNameDraftDirty = false
    @FocusState private var isLockNameFocused: Bool

    private var accent: Color {
        store.status.isUnlocked ? Color(red: 0.35, green: 0.86, blue: 0.58) : Color(red: 0.35, green: 0.72, blue: 1.0)
    }

    private var lockNameBinding: Binding<String> {
        Binding(
            get: { lockNameDraft },
            set: { newValue in
                lockNameDraft = newValue
                isLockNameDraftDirty = newValue.trimmingCharacters(in: .whitespacesAndNewlines) != store.lockName
            }
        )
    }

    var body: some View {
        PanelSurface {
            VStack(alignment: .leading, spacing: 14) {
                Label("Settings", systemImage: "slider.horizontal.3")
                    .font(.headline)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "door.left.hand.closed")
                            .foregroundStyle(accent)
                        Text("Lock Name")
                            .font(.caption.weight(.bold))
                    }

                    TextField(DoorAdminStore.defaultLockName, text: lockNameBinding)
                        .textFieldStyle(.roundedBorder)
                        .focused($isLockNameFocused)
                        .onSubmit {
                            commitLockName()
                        }
                        .onChange(of: isLockNameFocused) { _, isFocused in
                            if !isFocused {
                                commitLockName()
                            } else if !isLockNameDraftDirty {
                                lockNameDraft = store.lockName
                            }
                        }

                    if !store.isApplyingControllerSetting {
                        Text(store.lockNameStatus)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                HStack(alignment: .firstTextBaseline) {
                    Label("Auto-lock", systemImage: "timer")
                        .font(.caption.weight(.bold))
                    Spacer()
                    Text("\(store.status.autoLockSeconds)s")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Lock after \(store.status.autoLockSeconds) seconds")
                        .font(.title3.weight(.semibold))
                        .contentTransition(.numericText())

                    Slider(
                        value: Binding(
                            get: { Double(store.status.autoLockSeconds) },
                            set: { store.updateAutoLockSeconds(Int($0.rounded())) }
                        ),
                        in: Double(store.autoLockRange.lowerBound) ... Double(store.autoLockRange.upperBound),
                        step: 5
                    )
                    .tint(accent)
                    .controlSize(.small)

                    HStack {
                        Text("\(store.autoLockRange.lowerBound)s")
                        Spacer()
                        Text("\(store.autoLockRange.upperBound)s")
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)

                    if !store.isApplyingControllerSetting {
                        Text(store.autoLockStatus)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(store.isBusy)

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Label("Servo Angles", systemImage: "dial.low")
                            .font(.caption.weight(.bold))
                        Spacer()
                        Text("\(store.status.lockAngle)° / \(store.status.unlockAngle)°")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                    }

                    servoAngleSlider(
                        title: "Rest angle",
                        value: store.status.lockAngle,
                        setValue: store.updateLockServoAngle
                    )

                    servoAngleSlider(
                        title: "Push angle",
                        value: store.status.unlockAngle,
                        setValue: store.updateUnlockServoAngle
                    )

                    Button {
                        store.resetServoAnglesToDefaults()
                    } label: {
                        Label("Reset to Defaults", systemImage: "arrow.counterclockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(accent)

                    Text(servoAnglesHelpText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .disabled(store.isBusy)

                if let countdownText = store.status.autoLockCountdownText {
                    Label(countdownText, systemImage: "hourglass")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(accent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .contentTransition(.numericText())
                }
            }
        }
        .onAppear {
            lockNameDraft = store.lockName
            isLockNameDraftDirty = false
        }
        .onChange(of: store.lockName) { _, name in
            if !isLockNameFocused || !isLockNameDraftDirty {
                lockNameDraft = name
                isLockNameDraftDirty = false
            }
        }
    }

    private func servoAngleSlider(title: String, value: Int, setValue: @escaping (Int) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Spacer()
                Text("\(value)°")
                    .font(.callout.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Slider(
                value: Binding(
                    get: { Double(value) },
                    set: { setValue(Int($0.rounded())) }
                ),
                in: Double(store.servoAngleRange.lowerBound) ... Double(store.servoAngleRange.upperBound),
                step: 1
            )
            .tint(accent)
            .controlSize(.small)
        }
    }

    private var servoAnglesHelpText: String {
        let rangeText = "Safe range \(store.servoAngleRange.lowerBound)°-\(store.servoAngleRange.upperBound)°, keep \(store.status.servoMinAngleGap)° apart"
        guard !store.isApplyingControllerSetting else { return rangeText }
        return "\(store.servoAnglesStatus) - \(rangeText.lowercased())"
    }

    private func commitLockName() {
        let trimmedName = lockNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty {
            lockNameDraft = store.lockName
            isLockNameDraftDirty = false
            return
        }

        store.updateLockName(trimmedName)
        lockNameDraft = store.lockName
        isLockNameDraftDirty = false
    }
}
