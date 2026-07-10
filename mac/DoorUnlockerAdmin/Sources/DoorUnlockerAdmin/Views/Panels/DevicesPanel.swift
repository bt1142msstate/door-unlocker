import DoorUnlockerCore
import SwiftUI

struct DevicesPanel: View {
    @ObservedObject var store: DoorAdminStore
    @State private var renameText = ""

    var body: some View {
        PanelSurface {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Trusted Devices")
                        .font(.headline)
                    Spacer()
                    StatusPill(text: store.trustedDevicesCountText, symbol: "iphone.gen3", tint: .secondary)
                    Button(role: .destructive) {
                        store.clearAllDevices()
                    } label: {
                        Label("Clear All", systemImage: "trash")
                    }
                    .disabled(!store.isConnected || store.isBusy || store.pairedDevices.isEmpty)
                }

                if store.pairedDevices.isEmpty {
                    if store.trustedDeviceRosterSummary.trustedCount > 0 {
                        ContentUnavailableView {
                            Label(trustedDeviceTitle, systemImage: "iphone.gen3")
                        } description: {
                            Text(trustedDeviceDescription)
                        }
                        .frame(maxWidth: .infinity, minHeight: 130)
                    } else {
                        ContentUnavailableView("No trusted devices", systemImage: "iphone.slash")
                            .frame(maxWidth: .infinity, minHeight: 130)
                    }
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

    private var trustedDeviceTitle: String {
        let count = store.trustedDeviceRosterSummary.trustedCount
        return count == 1 ? "1 trusted device" : "\(count) trusted devices"
    }

    private var trustedDeviceDescription: String {
        if store.isConnected {
            return "Loading trusted device details."
        }
        return "Connect USB-C to view and manage the complete trusted-device list."
    }
}
