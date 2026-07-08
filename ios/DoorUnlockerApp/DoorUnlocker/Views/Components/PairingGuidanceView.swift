import SwiftUI

struct PairingGuidanceView: View {
    @ObservedObject var controller: DoorUnlockerController
    let accent: Color
    @Binding var isInviteSheetPresented: Bool

    var body: some View {
        if controller.activePairingInvite != nil && !controller.hasTrustedPairingForSecureCommand {
            PairingInviteRecipientPanel(controller: controller, accent: accent)
        } else if controller.canPair {
            Label(
                "Tap Pair This iPhone, then approve its code from a trusted device or USB-C.",
                systemImage: "key.fill"
            )
            .font(.footnote.weight(.medium))
            .foregroundStyle(accent)
        } else if controller.isPairingThisPhone {
            PairingApprovalPanel(controller: controller, accent: accent)
        } else if controller.canApprovePendingPairing {
            TrustedPairingApprovalPanel(controller: controller, accent: accent)
        } else if controller.canAdministerPairing {
            TrustedPairingAdminPanel(
                controller: controller,
                accent: accent,
                isInviteSheetPresented: $isInviteSheetPresented
            )
        } else if controller.needsUsbPairingMode {
            Label(
                "Use a trusted device or USB-C to allow new-device pairing.",
                systemImage: "key.slash.fill"
            )
            .font(.footnote.weight(.medium))
            .foregroundStyle(.secondary)
        }
    }
}

struct DeviceInviteSheet: View {
    @ObservedObject var controller: DoorUnlockerController
    let accent: Color
    @Environment(\.dismiss) private var dismiss

    private var isPairingOpen: Bool {
        controller.pairingState == "Pairing enabled" || controller.isPairingPending
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                InviteHeader(lockName: controller.lockName, isPairingOpen: isPairingOpen, accent: accent)
                InviteSteps()

                if controller.canApprovePendingPairing {
                    TrustedPairingApprovalPanel(controller: controller, accent: accent)
                        .padding(12)
                        .background(
                            Color.black.opacity(0.22),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                }

                Spacer(minLength: 0)
                DeviceInviteActions(controller: controller, accent: accent)
            }
            .padding(20)
            .background(Color(red: 0.03, green: 0.04, blue: 0.05).ignoresSafeArea())
            .foregroundStyle(.white)
            .navigationTitle("Invite Device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                controller.beginInviteFlow()
            }
        }
    }
}

private struct PairingInviteRecipientPanel: View {
    @ObservedObject var controller: DoorUnlockerController
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                controller.activePairingInvite?.title ?? "Door Unlocker invite",
                systemImage: "person.badge.key.fill"
            )
            .font(.footnote.weight(.bold))
            .foregroundStyle(accent)

            if let status = controller.activePairingInviteStatus {
                Text(status)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            if controller.canPair {
                Button {
                    controller.pairThisPhone()
                } label: {
                    Label("Pair This iPhone", systemImage: "key.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(accent)
            }
        }
        .padding(12)
        .background(Color.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct PairingApprovalPanel: View {
    @ObservedObject var controller: DoorUnlockerController
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Enter this code in the Mac app.", systemImage: "keyboard.fill")
                .font(.footnote.weight(.medium))
                .foregroundStyle(accent)

            if let code = controller.pairingApprovalCode {
                PairingCodeBadge(code: code)
            }
        }
    }
}

private struct PairingCodeBadge: View {
    let code: String

    var body: some View {
        Text(code)
            .font(.system(size: 34, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .lineLimit(1)
            .tracking(6)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .center)
            .background(Color.black.opacity(0.34), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct TrustedPairingApprovalPanel: View {
    @ObservedObject var controller: DoorUnlockerController
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Approve the new device.", systemImage: "person.badge.plus.fill")
                .font(.footnote.weight(.medium))
                .foregroundStyle(accent)

            HStack(spacing: 10) {
                TextField("4-digit code", text: $controller.pairingAdminApprovalCode)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .font(.system(.body, design: .monospaced))
                    .textFieldStyle(.roundedBorder)

                Button("Approve") {
                    controller.approvePendingPairing()
                }
                .buttonStyle(.borderedProminent)
                .tint(accent)

                Button("Reject") {
                    controller.rejectPendingPairing()
                }
                .buttonStyle(.bordered)
            }
        }
    }
}

private struct TrustedPairingAdminPanel: View {
    @ObservedObject var controller: DoorUnlockerController
    let accent: Color
    @Binding var isInviteSheetPresented: Bool

    var body: some View {
        HStack(spacing: 10) {
            Label(adminStatusText, systemImage: "person.badge.key.fill")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            Button {
                controller.beginInviteFlow()
                isInviteSheetPresented = true
            } label: {
                Label("Invite", systemImage: "square.and.arrow.up")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderedProminent)
            .tint(accent)
            .accessibilityLabel("Invite device")

            Button(pairingModeButtonTitle) {
                controller.pairingState == "Pairing enabled"
                    ? controller.stopNewDevicePairing()
                    : controller.allowNewDevicePairing()
            }
            .buttonStyle(.bordered)
            .tint(accent)
        }
    }

    private var adminStatusText: String {
        controller.pairingState == "Pairing enabled"
            ? "New-device pairing is open."
            : "This iPhone can approve new devices."
    }

    private var pairingModeButtonTitle: String {
        controller.pairingState == "Pairing enabled" ? "Stop" : "Allow"
    }
}

private struct InviteHeader: View {
    let lockName: String
    let isPairingOpen: Bool
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: isPairingOpen ? "person.badge.plus.fill" : "person.badge.key.fill")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(accent)

            Text("Add someone to \(lockName)")
                .font(.title2.weight(.bold))

            Text(inviteExplanation)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var inviteExplanation: String {
        "The invite does not include a key. The new device generates its own private key, and this trusted device still has to approve the code."
    }
}

private struct InviteSteps: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            InviteStepRow(
                number: "1",
                title: "Share the invite",
                detail: "The link opens Door Unlocker on the iPhone you want to add."
            )
            InviteStepRow(
                number: "2",
                title: "Pairing opens here",
                detail: "This trusted iPhone sends a signed command to let one new device request access."
            )
            InviteStepRow(
                number: "3",
                title: "Approve the code",
                detail: "The new iPhone shows a 4-digit code. Type that code here before access is trusted."
            )
        }
    }
}

private struct InviteStepRow: View {
    let number: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.caption.weight(.bold))
                .foregroundStyle(.black)
                .frame(width: 24, height: 24)
                .background(Color.white, in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.footnote.weight(.bold))

                Text(detail)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct DeviceInviteActions: View {
    @ObservedObject var controller: DoorUnlockerController
    let accent: Color

    var body: some View {
        VStack(spacing: 10) {
            ShareLink(
                item: controller.deviceInviteShareURL,
                subject: Text("Door Unlocker invite"),
                message: Text(controller.deviceInviteShareMessage)
            ) {
                Label("Share Invite", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.borderedProminent)
            .tint(accent)

            if controller.pairingState == "Pairing enabled" {
                Button {
                    controller.stopNewDevicePairing()
                } label: {
                    Label("Stop Pairing", systemImage: "key.slash.fill")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
            }
        }
    }
}
