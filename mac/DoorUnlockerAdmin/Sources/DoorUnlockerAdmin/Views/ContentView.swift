import SwiftUI

struct ContentView: View {
    @ObservedObject var store: DoorAdminStore

    var body: some View {
        NavigationSplitView {
            SidebarView(store: store)
                .navigationSplitViewColumnWidth(min: 260, ideal: 300)
        } detail: {
            DetailView(store: store)
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    store.refreshPorts()
                } label: {
                    Label("Refresh Ports", systemImage: "arrow.triangle.2.circlepath")
                }

                Button {
                    store.isConnected ? store.disconnect() : store.connect()
                } label: {
                    Label(store.isConnected ? "Disconnect" : "Connect", systemImage: store.isConnected ? "cable.connector.slash" : "cable.connector")
                }
                .disabled(store.isBusy || store.selectedPortID == nil)
            }
        }
    }
}

private struct SidebarView: View {
    @ObservedObject var store: DoorAdminStore

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Door Unlocker Admin", systemImage: "lock.shield")
                        .font(.headline)

                    Picker("USB Port", selection: $store.selectedPortID) {
                        ForEach(store.ports) { port in
                            Text(port.displayName).tag(Optional(port.id))
                        }
                    }
                    .labelsHidden()
                    .disabled(store.isConnected || store.ports.isEmpty)

                    if store.ports.isEmpty {
                        Text("No USB serial controller found")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Controller") {
                SidebarMetric(title: "Connection", value: store.isConnected ? "Connected" : "Disconnected", symbol: "dot.radiowaves.left.and.right")
                SidebarMetric(title: "State", value: store.status.stateTitle, symbol: store.status.isUnlocked ? "lock.open.fill" : "lock.fill")
                SidebarMetric(title: "Pairing", value: store.status.pairingTitle, symbol: "person.badge.key.fill")
                SidebarMetric(title: "Trusted Devices", value: "\(store.status.pairedCount)/\(max(store.status.maxPairs, 4))", symbol: "iphone.gen3")
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
            VStack(alignment: .leading, spacing: 16) {
                HeaderView(store: store)
                ControlsPanel(store: store)
                PairingPanel(store: store)
                DevicesPanel(store: store)
                LogPanel(lines: store.logLines)
            }
            .padding(24)
        }
        .background(.background)
    }
}

private struct HeaderView: View {
    @ObservedObject var store: DoorAdminStore

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                Circle()
                    .fill(store.status.isUnlocked ? .green.opacity(0.16) : .blue.opacity(0.14))
                Image(systemName: store.status.isUnlocked ? "lock.open.fill" : "lock.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(store.status.isUnlocked ? .green : .blue)
            }
            .frame(width: 68, height: 68)

            VStack(alignment: .leading, spacing: 4) {
                Text(store.status.stateTitle)
                    .font(.largeTitle.weight(.semibold))
                Text(store.message)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                store.refreshAll()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(!store.isConnected || store.isBusy)
        }
    }
}

private struct ControlsPanel: View {
    @ObservedObject var store: DoorAdminStore

    var body: some View {
        GroupBox("Lock Control") {
            HStack(spacing: 12) {
                Button {
                    store.unlock()
                } label: {
                    Label("Unlock", systemImage: "lock.open.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)

                Button {
                    store.lock()
                } label: {
                    Label("Lock", systemImage: "lock.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .disabled(!store.isConnected || store.isBusy)
            .padding(.vertical, 4)
        }
    }
}

private struct PairingPanel: View {
    @ObservedObject var store: DoorAdminStore

    var body: some View {
        GroupBox("Pairing") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(store.status.hasPendingRequest ? "Pending Approval" : "Mode \(store.status.pairingTitle)", systemImage: "person.badge.key.fill")
                        .font(.headline)

                    Spacer()

                    Button("Enable") {
                        store.enablePairingMode()
                    }
                    .disabled(!store.isConnected || store.isBusy || store.status.pairingMode == "enabled")

                    Button("Disable") {
                        store.disablePairingMode()
                    }
                    .disabled(!store.isConnected || store.isBusy || store.status.pairingMode != "enabled")
                }

                if let pendingFingerprint = store.status.pendingFingerprint {
                    LabeledContent("Pending fingerprint", value: pendingFingerprint)
                }

                HStack(spacing: 10) {
                    TextField("Approval code from iPhone", text: $store.approvalCode)
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
            .padding(.vertical, 4)
        }
    }
}

private struct DevicesPanel: View {
    @ObservedObject var store: DoorAdminStore

    var body: some View {
        GroupBox("Trusted Devices") {
            VStack(alignment: .leading, spacing: 12) {
                if store.pairedDevices.isEmpty {
                    ContentUnavailableView("No trusted devices", systemImage: "iphone.slash")
                        .frame(maxWidth: .infinity, minHeight: 150)
                } else {
                    List(store.pairedDevices, selection: $store.selectedDeviceID) { device in
                        HStack(spacing: 12) {
                            Text("#\(device.slot)")
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 38, alignment: .leading)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(device.fingerprint)
                                    .font(.system(.body, design: .monospaced))
                                Text("Counter \(device.counter)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()
                        }
                        .tag(device.id)
                    }
                    .frame(minHeight: 180)
                }

                HStack {
                    Button(role: .destructive) {
                        store.removeSelectedDevice()
                    } label: {
                        Label("Remove Selected", systemImage: "minus.circle")
                    }
                    .disabled(!store.isConnected || store.isBusy || store.selectedDeviceID == nil)

                    Spacer()

                    Button(role: .destructive) {
                        store.clearAllDevices()
                    } label: {
                        Label("Clear All", systemImage: "trash")
                    }
                    .disabled(!store.isConnected || store.isBusy || store.pairedDevices.isEmpty)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

private struct LogPanel: View {
    let lines: [String]

    var body: some View {
        GroupBox("USB Log") {
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
                .padding(.vertical, 4)
            }
            .frame(minHeight: 120, maxHeight: 180)
        }
    }
}
