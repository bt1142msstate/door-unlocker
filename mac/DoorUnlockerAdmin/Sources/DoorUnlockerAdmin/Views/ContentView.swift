import DoorUnlockerCore
import SwiftUI

struct ContentView: View {
    @ObservedObject var store: DoorAdminStore

    var body: some View {
        NavigationSplitView {
            SidebarView(store: store)
                .navigationSplitViewColumnWidth(min: 260, ideal: 292)
        } detail: {
            DetailView(store: store)
        }
    }
}

private struct SidebarView: View {
    @ObservedObject var store: DoorAdminStore

    var body: some View {
        List {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Door Unlocker")
                            .font(.headline)
                        Text("Admin")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "door.left.hand.closed")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.green)
                }
                .padding(.vertical, 4)
            }

            Section("Door") {
                SidebarMetric(title: "State", value: store.status.stateTitle, symbol: store.status.isUnlocked ? "lock.open.fill" : "lock.fill")
                SidebarMetric(title: "Connection", value: store.primaryConnectionTitle, symbol: store.isWirelessReady ? "wave.3.right" : "cable.connector")
                SidebarMetric(title: "Pairing", value: store.status.pairingTitle, symbol: "person.badge.key.fill")
                SidebarMetric(title: "Trusted", value: "\(store.status.pairedCount)/\(max(store.status.maxPairs, 4))", symbol: "iphone.gen3")
            }

            if let error = store.lastError {
                Section("Issue") {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.callout)
                }
            }
        }
        .listStyle(.sidebar)
    }
}

private struct SidebarMetric: View {
    let title: String
    let value: String
    let symbol: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .lineLimit(1)
            }
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
        }
    }
}

private struct DetailView: View {
    @ObservedObject var store: DoorAdminStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HeroControl(store: store)
                ConnectionPanel(store: store)
                AutoLockPanel(store: store)
                PairingPanel(store: store)
                DevicesPanel(store: store)
            }
            .padding(26)
        }
        .background(.background)
    }
}

private struct HeroControl: View {
    @ObservedObject var store: DoorAdminStore
    @State private var isHovering = false

    private var accent: Color {
        store.status.isUnlocked ? Color(red: 0.35, green: 0.86, blue: 0.58) : Color(red: 0.35, green: 0.72, blue: 1.0)
    }

    private var currentSymbol: String {
        store.status.isUnlocked ? "lock.open.fill" : "lock.fill"
    }

    private var actionTitle: String {
        if store.isBusy {
            return store.status.isUnlocked ? "Locking..." : "Unlocking..."
        }

        guard store.canSendDoorCommand else {
            return "Connect first"
        }

        return store.status.isUnlocked ? "Click to lock" : "Click to unlock"
    }

    private var stateTitle: String {
        let title = store.status.stateTitle
        return title == "Unknown" ? "Disconnected" : title
    }

    private var subtitle: String {
        if store.isBusy {
            return store.message
        }

        if store.message == "Door locked" || store.message == "Door unlocked" {
            return store.canSendDoorCommand ? "Controller connected" : "Connect to the controller"
        }

        return store.message
    }

    var body: some View {
        HStack(spacing: 22) {
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
                            accent.opacity(store.isBusy ? 0.75 : 0),
                            style: StrokeStyle(lineWidth: 5, lineCap: .round)
                        )
                        .rotationEffect(.degrees(store.isBusy ? 360 : 0))
                        .animation(store.isBusy ? .linear(duration: 1.0).repeatForever(autoreverses: false) : .default, value: store.isBusy)

                    VStack(spacing: 11) {
                        Image(systemName: currentSymbol)
                            .font(.system(size: 46, weight: .semibold))
                            .symbolRenderingMode(.hierarchical)
                        Text(actionTitle)
                            .font(.title3.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)
                    }
                    .foregroundStyle(store.canSendDoorCommand ? accent : .secondary)
                }
                .frame(width: 158, height: 158)
                .scaleEffect(isHovering && store.canSendDoorCommand ? 1.035 : 1)
                .animation(.spring(response: 0.26, dampingFraction: 0.78), value: isHovering)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!store.canSendDoorCommand || store.isBusy)
            .onHover { isHovering = $0 }

            VStack(alignment: .leading, spacing: 13) {
                HStack(spacing: 10) {
                    StatusPill(text: stateTitle, symbol: currentSymbol, tint: accent)
                    StatusPill(text: store.primaryConnectionTitle, symbol: store.isWirelessReady ? "wave.3.right" : "cable.connector", tint: .secondary)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text(stateTitle)
                        .font(.system(size: 46, weight: .semibold, design: .rounded))
                        .contentTransition(.numericText())

                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                if let countdownText = store.status.autoLockCountdownText {
                    Label(countdownText, systemImage: "timer")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(accent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .contentTransition(.numericText())
                }

                if store.isBusy {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            Spacer()
        }
        .padding(24)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)
                .overlay(alignment: .topLeading) {
                    LinearGradient(
                        colors: [accent.opacity(0.16), .clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(accent.opacity(0.16), lineWidth: 1)
        }
    }
}

private struct StatusPill: View {
    let text: String
    let symbol: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.thinMaterial, in: Capsule())
    }
}

private struct PanelSurface<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            }
    }
}

private struct ConnectionPanel: View {
    @ObservedObject var store: DoorAdminStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Connection")
                    .font(.headline)
                Spacer()
                StatusPill(text: store.primaryConnectionTitle, symbol: store.isWirelessReady ? "wave.3.right" : "cable.connector", tint: .secondary)
            }

            HStack(alignment: .top, spacing: 12) {
                WirelessStatusTile(store: store)

                PanelSurface {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label("USB-C Controller", systemImage: "cable.connector")
                                .font(.headline)
                            Spacer()
                            Text(store.isConnected ? "Connected" : "Disconnected")
                                .foregroundStyle(.secondary)
                        }

                        Text("Used for trusted admin access. When connected, lock control and settings use USB-C automatically.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Label(
                            store.isConnected
                                ? "This Mac is trusted automatically over USB-C."
                                : "Plug in the controller and the app will connect automatically.",
                            systemImage: store.isConnected ? "checkmark.circle.fill" : "cable.connector.slash"
                        )
                        .font(.callout)
                        .foregroundStyle(store.isConnected ? .green : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

private struct WirelessStatusTile: View {
    @ObservedObject var store: DoorAdminStore

    var body: some View {
        PanelSurface {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Wireless Control", systemImage: "wave.3.right")
                        .font(.headline)
                    Spacer()
                    Text(store.wirelessConnectionState)
                        .foregroundStyle(.secondary)
                }

                Label(statusText, systemImage: statusSymbol)
                .font(.callout)
                .foregroundStyle(store.isWirelessReady ? .green : .secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var statusText: String {
        if store.isConnected && store.isWirelessReady {
            return "USB-C is active. Wireless is also available as a fallback."
        }
        if store.isConnected {
            return "Using USB-C. Wireless stays in the background for when the cable is not connected."
        }
        if store.isWirelessReady {
            return "Wireless commands are available."
        }
        return "The app connects wirelessly in the background when the controller is nearby."
    }

    private var statusSymbol: String {
        store.isWirelessReady ? "checkmark.circle.fill" : "antenna.radiowaves.left.and.right"
    }
}

private struct AutoLockPanel: View {
    @ObservedObject var store: DoorAdminStore

    private var accent: Color {
        store.status.isUnlocked ? Color(red: 0.35, green: 0.86, blue: 0.58) : Color(red: 0.35, green: 0.72, blue: 1.0)
    }

    var body: some View {
        PanelSurface {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Label("Auto-lock", systemImage: "timer")
                        .font(.headline)
                    Spacer()
                    StatusPill(text: "\(store.status.autoLockSeconds)s", symbol: "clock", tint: accent)
                }

                Stepper(
                    value: Binding(
                        get: { store.status.autoLockSeconds },
                        set: { store.updateAutoLockSeconds($0) }
                    ),
                    in: store.autoLockRange,
                    step: 5
                ) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Lock after \(store.status.autoLockSeconds) seconds")
                            .font(.title3.weight(.semibold))
                            .contentTransition(.numericText())
                        Text(store.autoLockStatus)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
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
    }
}

private struct PairingPanel: View {
    @ObservedObject var store: DoorAdminStore

    var body: some View {
        PanelSurface {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Add a Device")
                        .font(.headline)
                    Spacer()
                    Button(store.status.pairingMode == "enabled" ? "Stop Pairing" : "Allow New Device") {
                        store.status.pairingMode == "enabled" ? store.disablePairingMode() : store.enablePairingMode()
                    }
                    .disabled(!store.isConnected || store.isBusy)
                }

                if store.status.hasPendingRequest {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(store.status.pendingName ?? "Pending device")
                            .font(.title3.weight(.semibold))
                        Text("Enter the 4-digit code shown on that device.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 10) {
                        TextField("4-digit code", text: $store.approvalCode)
                            .font(.system(.body, design: .monospaced))
                            .textFieldStyle(.roundedBorder)

                        Button("Approve") {
                            store.approvePairing()
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Reject") {
                            store.rejectPairing()
                        }
                    }
                    .disabled(!store.isConnected || store.isBusy)
                } else {
                    Label(
                        store.isConnected
                            ? "Enable pairing, then request pairing from the device you want to trust."
                            : "Connect the controller over USB-C to approve a new device.",
                        systemImage: store.isConnected ? "person.badge.plus" : "cable.connector"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct DevicesPanel: View {
    @ObservedObject var store: DoorAdminStore
    @State private var renameText = ""

    var body: some View {
        PanelSurface {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Trusted Devices")
                        .font(.headline)
                    Spacer()
                    StatusPill(text: "\(store.pairedDevices.count)", symbol: "iphone.gen3", tint: .secondary)
                    Button(role: .destructive) {
                        store.clearAllDevices()
                    } label: {
                        Label("Clear All", systemImage: "trash")
                    }
                    .disabled(!store.isConnected || store.isBusy || store.pairedDevices.isEmpty)
                }

                if store.pairedDevices.isEmpty {
                    ContentUnavailableView("No trusted devices", systemImage: "iphone.slash")
                        .frame(maxWidth: .infinity, minHeight: 130)
                } else {
                    List(store.pairedDevices, selection: $store.selectedDeviceID) { device in
                        HStack(spacing: 12) {
                            Image(systemName: device.displayName.localizedCaseInsensitiveContains("mac") ? "macbook" : "iphone.gen3")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                                .frame(width: 30)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(device.displayName)
                                    .font(.body.weight(.medium))
                                Text(device.kindTitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()
                        }
                        .tag(device.id)
                    }
                    .frame(minHeight: 190)
                }

                HStack {
                    Button(role: .destructive) {
                        store.removeSelectedDevice()
                    } label: {
                        Label("Remove Selected", systemImage: "minus.circle")
                    }
                    .disabled(!store.isConnected || store.isBusy || store.selectedDeviceID == nil)
                    TextField("Device name", text: $renameText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                        .disabled(!store.isConnected || store.isBusy || store.selectedDeviceID == nil)
                    Button("Rename") {
                        store.renameSelectedDevice(to: renameText)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!store.isConnected || store.isBusy || store.selectedDeviceID == nil || renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Spacer()
                }
            }
        }
        .onAppear {
            renameText = store.selectedDevice?.displayName ?? ""
        }
        .onChange(of: store.selectedDeviceID) {
            renameText = store.selectedDevice?.displayName ?? ""
        }
        .onChange(of: store.pairedDevices) {
            if let selectedDevice = store.selectedDevice {
                renameText = selectedDevice.displayName
            }
        }
    }
}
