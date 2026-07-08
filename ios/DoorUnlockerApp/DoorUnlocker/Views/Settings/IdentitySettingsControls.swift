import SwiftUI

struct LockNameControl: View {
    @ObservedObject var controller: DoorUnlockerController
    let accent: Color
    @State private var draft = ""
    @State private var commitTask: Task<Void, Never>?
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "door.left.hand.closed")
                    .foregroundStyle(accent)
                Text("Lock Name")
                    .font(.caption.weight(.bold))
            }

            TextField(DoorStatusStore.defaultLockName, text: $draft)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.done)
                .focused($isFocused)
                .onSubmit(scheduleCommit)
                .onChange(of: isFocused) { _, isFocused in
                    if !isFocused { scheduleCommit() }
                }

            Text(controller.lockNameStatus)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .disabled(controller.isAuthenticatingSettings)
        .padding(12)
        .background(Color.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onAppear { draft = controller.lockName }
        .onDisappear(perform: commitNow)
        .onChange(of: controller.lockName) { _, name in
            if !isFocused { draft = name }
        }
    }

    private func scheduleCommit() {
        commitTask?.cancel()
        commitTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            commitTask = nil
            commitNow()
        }
    }

    private func commitNow() {
        let trimmedName = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty || trimmedName == controller.lockName {
            draft = controller.lockName
            return
        }

        controller.updateLockName(trimmedName)
        draft = controller.lockName
    }
}

struct DeviceDisplayNameControl: View {
    @ObservedObject var controller: DoorUnlockerController
    let accent: Color
    @State private var draft = ""
    @State private var commitTask: Task<Void, Never>?
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "iphone.gen3")
                    .foregroundStyle(accent)
                Text("This iPhone")
                    .font(.caption.weight(.bold))
                Spacer(minLength: 8)
                Text(controller.deviceDisplayName)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            TextField("iPhone Air", text: $draft)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.done)
                .focused($isFocused)
                .onSubmit(scheduleCommit)
                .onChange(of: isFocused) { _, isFocused in
                    if !isFocused { scheduleCommit() }
                }

            Text(controller.deviceDisplayNameStatus)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .disabled(controller.isAuthenticatingSettings)
        .padding(12)
        .background(Color.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onAppear { draft = controller.deviceDisplayName }
        .onDisappear(perform: commitNow)
        .onChange(of: controller.deviceDisplayName) { _, name in
            if !isFocused { draft = name }
        }
    }

    private func scheduleCommit() {
        commitTask?.cancel()
        commitTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            commitTask = nil
            commitNow()
        }
    }

    private func commitNow() {
        let trimmedName = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty || trimmedName == controller.deviceDisplayName {
            draft = controller.deviceDisplayName
            return
        }

        controller.updateDeviceDisplayName(trimmedName)
        draft = controller.deviceDisplayName
    }
}
