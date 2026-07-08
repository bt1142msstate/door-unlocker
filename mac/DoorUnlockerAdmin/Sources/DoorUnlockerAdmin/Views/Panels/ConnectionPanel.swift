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
                    Spacer()
                    Text(store.primaryConnectionTitle)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(store.connectionSummaryTitle)
                        .font(.title3.weight(.semibold))
                    Text(store.connectionSummaryDetail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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

                PerformanceTraceView(entries: store.runtimeTelemetryEntries)
            }
        }
    }
}

private struct PerformanceTraceView: View {
    let entries: [DoorAdminStore.RuntimeTelemetryEntry]

    var body: some View {
        DisclosureGroup {
            if entries.isEmpty {
                Text("No launch timing captured yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 2)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(entries) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(entry.timeText)
                                .font(.caption.monospacedDigit().weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 58, alignment: .trailing)

                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.title)
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(1)

                                if let details = entry.details, !details.isEmpty {
                                    Text(details)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }

                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(.top, 2)
            }
        } label: {
            HStack(spacing: 8) {
                Label("Launch Timing", systemImage: "speedometer")
                    .font(.callout.weight(.semibold))
                Spacer()
                Text("\(entries.count) events")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
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
                        .padding(8)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
                        .padding(8)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
