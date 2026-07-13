import DoorUnlockerCore
import SwiftUI

struct ConnectionPanel: View {
    @ObservedObject var store: DoorAdminStore

    var body: some View {
        PanelSurface {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Label("Connection", systemImage: store.isConnected ? "cable.connector" : "wave.3.right")
                        .font(.headline)
                }

                Divider()

                HStack(alignment: .top, spacing: 14) {
                    ConnectionModeRow(
                        title: "USB-C",
                        value: store.isConnected ? "Connected" : "Auto",
                        symbol: store.isConnected ? "checkmark.circle.fill" : "cable.connector",
                        tint: store.isConnected ? .green : .secondary,
                        detail: store.isConnected
                            ? "Trusted admin access is active."
                            : "Plug in the controller to use USB-C."
                    )

                    Divider()

                    ConnectionModeRow(
                        title: "Wireless",
                        value: store.wirelessConnectionDisplayValue,
                        symbol: store.wirelessConnectionDisplaySymbol,
                        tint: store.isWirelessConnectionDisplayReady ? .green : .secondary,
                        detail: store.isConnected
                            ? "Mac wireless is paused; Bluetooth peers still report below."
                            : "Connects on demand for lock commands."
                    )
                }

                Divider()

                ConnectedDevicesList(
                    status: store.displayedStatus,
                    countText: store.connectedDevicesCountText,
                    emptyMessage: store.connectedDevicesEmptyMessage
                )
            }
        }
    }
}

private struct ConnectedDevicesList: View {
    let status: ControllerStatus
    let countText: String
    let emptyMessage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Connected Devices", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.callout.weight(.semibold))
                Spacer()
                Text(countText)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }

            if status.connectedDevices.isEmpty {
                Text(emptyMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(status.connectedDevices) { device in
                        HStack(spacing: 10) {
                            Image(systemName: device.displayName.localizedCaseInsensitiveContains("mac") ? "macbook" : "iphone.gen3")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(device.displayName)
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(1)
                                Text(device.trustTitle)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 3)
                    }

                    if status.unidentifiedConnectedDeviceCount > 0 {
                        HStack(spacing: 10) {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(Self.unidentifiedDeviceTitle(count: status.unidentifiedConnectedDeviceCount))
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(1)
                                Text("Identifying over Bluetooth")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
        }
    }

    private static func unidentifiedDeviceTitle(count: Int) -> String {
        count == 1 ? "1 Bluetooth device" : "\(count) Bluetooth devices"
    }
}

private struct ConnectionModeRow: View {
    let title: String
    let value: String
    let symbol: String
    let tint: Color
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.callout.weight(.semibold))
                    Text(value)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
