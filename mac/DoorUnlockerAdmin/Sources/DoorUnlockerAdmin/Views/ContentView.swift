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

            Section("Connections") {
                SidebarMetric(title: "Primary", value: store.primaryConnectionTitle, symbol: "point.3.connected.trianglepath.dotted")
                SidebarMetric(title: "Bluetooth", value: store.wirelessConnectionState, symbol: "wave.3.right")
                SidebarMetric(title: "USB", value: store.isConnected ? "Connected" : "Disconnected", symbol: "cable.connector")
            }

            Section("Controller") {
                SidebarMetric(title: "State", value: store.status.stateTitle, symbol: store.status.isUnlocked ? "lock.open.fill" : "lock.fill")
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
                PairingPanel(store: store)
                DevicesPanel(store: store)
                LogPanel(lines: store.logLines)
            }
            .padding(26)
        }
        .background(.background)
    }
}

private struct HeroControl: View {
    @ObservedObject var store: DoorAdminStore

    var body: some View {
        HStack(spacing: 22) {
            Button {
                store.toggleLock()
            } label: {
                ZStack {
                    Circle()
                        .fill(store.status.isUnlocked ? .blue.opacity(0.14) : .green.opacity(0.15))
                        .overlay {
                            Circle()
                                .stroke(store.status.isUnlocked ? .blue.opacity(0.22) : .green.opacity(0.24), lineWidth: 1)
                        }

                    VStack(spacing: 10) {
                        Image(systemName: store.status.isUnlocked ? "lock.fill" : "lock.open.fill")
                            .font(.system(size: 44, weight: .semibold))
                        Text(store.status.isUnlocked ? "Lock" : "Unlock")
                            .font(.title3.weight(.semibold))
                    }
                    .foregroundStyle(store.status.isUnlocked ? .blue : .green)
                }
                .frame(width: 150, height: 150)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!store.canSendDoorCommand || store.isBusy)

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    StatusPill(text: store.status.stateTitle, symbol: store.status.isUnlocked ? "lock.open.fill" : "lock.fill", tint: store.status.isUnlocked ? .green : .blue)
                    StatusPill(text: store.primaryConnectionTitle, symbol: store.isWirelessReady ? "wave.3.right" : "cable.connector", tint: .secondary)
                }

                Text(store.status.isUnlocked ? "Unlocked" : "Locked")
                    .font(.system(size: 44, weight: .semibold))
                    .contentTransition(.numericText())

                Text(store.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                if store.isBusy {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            Spacer()
        }
        .padding(22)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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

private struct ConnectionPanel: View {
    @ObservedObject var store: DoorAdminStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connections")
                .font(.headline)

            HStack(alignment: .top, spacing: 12) {
                ConnectionTile(
                    title: "Wireless",
                    subtitle: store.wirelessConnectionState,
                    symbol: "wave.3.right",
                    primaryTitle: store.wirelessPrimaryActionTitle,
                    primaryAction: {
                        store.toggleWirelessConnection()
                    },
                    secondaryTitle: "Pair This Mac",
                    secondaryAction: {
                        store.pairThisMacWireless()
                    },
                    isSecondaryDisabled: !store.isWirelessPairingReady || store.isBusy
                )

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("USB Admin", systemImage: "cable.connector")
                            .font(.headline)
                        Spacer()
                        Text(store.isConnected ? "Connected" : "Disconnected")
                            .foregroundStyle(.secondary)
                    }

                    Picker("USB Port", selection: $store.selectedPortID) {
                        ForEach(store.ports) { port in
                            Text(port.displayName).tag(Optional(port.id))
                        }
                    }
                    .labelsHidden()
                    .disabled(store.isConnected || store.ports.isEmpty)

                    HStack {
                        Button(store.isConnected ? "Disconnect" : "Connect") {
                            store.isConnected ? store.disconnect() : store.connect()
                        }
                        .disabled(store.isBusy || store.selectedPortID == nil)

                        Button("Refresh Ports") {
                            store.refreshPorts()
                        }
                    }
                    .buttonStyle(.bordered)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            if let code = store.wirelessPairingApprovalCode {
                Label("Mac pairing code: \(code)", systemImage: "key.horizontal.fill")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ConnectionTile: View {
    let title: String
    let subtitle: String
    let symbol: String
    let primaryTitle: String
    let primaryAction: () -> Void
    let secondaryTitle: String
    let secondaryAction: () -> Void
    let isSecondaryDisabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(title, systemImage: symbol)
                    .font(.headline)
                Spacer()
                Text(subtitle)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button(primaryTitle, action: primaryAction)
                    .buttonStyle(.borderedProminent)
                Button(secondaryTitle, action: secondaryAction)
                    .buttonStyle(.bordered)
                    .disabled(isSecondaryDisabled)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct PairingPanel: View {
    @ObservedObject var store: DoorAdminStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Pairing")
                    .font(.headline)
                Spacer()
                Button(store.status.pairingMode == "enabled" ? "Disable Pairing" : "Enable Pairing") {
                    store.status.pairingMode == "enabled" ? store.disablePairingMode() : store.enablePairingMode()
                }
                .disabled(!store.isConnected || store.isBusy)
            }

            if let pendingFingerprint = store.status.pendingFingerprint {
                VStack(alignment: .leading, spacing: 5) {
                    Text(store.status.pendingName ?? "Pending device")
                        .font(.title3.weight(.semibold))
                    Text(pendingFingerprint)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 10) {
                TextField("Approval code from iPhone or Mac", text: $store.approvalCode)
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
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct DevicesPanel: View {
    @ObservedObject var store: DoorAdminStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Trusted Devices")
                    .font(.headline)
                Spacer()
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
                            Text(device.fingerprint)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Text("#\(device.slot)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.tertiary)
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
                Spacer()
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct LogPanel: View {
    let lines: [String]

    var body: some View {
        DisclosureGroup("USB Log") {
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.vertical, 6)
            }
            .frame(minHeight: 100, maxHeight: 160)
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
