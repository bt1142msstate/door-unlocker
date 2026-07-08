import DoorUnlockerCore
import SwiftUI

struct PairingPanel: View {
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
                    .disabled(!(store.isConnected || store.isWirelessReady) || store.isBusy)
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
                    .disabled(!(store.isConnected || store.isWirelessReady) || store.isBusy)
                } else {
                    Label(
                        store.isConnected
                            ? "Enable pairing, then request pairing from the device you want to trust."
                            : "Use this trusted Mac wirelessly, or connect USB-C as a fallback, to approve a new device.",
                        systemImage: store.isConnected || store.isWirelessReady ? "person.badge.plus" : "cable.connector"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }
}
