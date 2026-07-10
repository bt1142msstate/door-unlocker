import DoorUnlockerCore
import SwiftUI

struct SidebarView: View {
    @ObservedObject var store: DoorAdminStore

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.lockName)
                        .font(.headline)
                    Text("Admin")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section("Controller") {
                SidebarMetric(title: "Status", value: store.controllerStatusTitle, symbol: store.controllerStatusSymbol)
                SidebarMetric(title: "Model", value: store.status.modelTitle, symbol: "rectangle.connected.to.line.below")
                SidebarMetric(title: "Connected", value: store.connectedDevicesCountText, symbol: "point.3.connected.trianglepath.dotted")
                SidebarMetric(title: "Trusted", value: store.trustedDevicesCountText, symbol: "iphone.gen3")
            }

            if let error = store.visibleLastError {
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
