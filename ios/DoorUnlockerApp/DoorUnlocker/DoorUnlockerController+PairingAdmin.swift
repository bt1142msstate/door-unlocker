import CoreBluetooth
import Foundation

extension DoorUnlockerController {
    var deviceInviteShareURL: URL {
        var components = URLComponents()
        components.scheme = "doorunlocker"
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "lock", value: lockName),
            URLQueryItem(name: "from", value: deviceDisplayName)
        ]
        return components.url ?? URL(string: "doorunlocker://pair")!
    }

    var deviceInviteShareMessage: String {
        "Open this Door Unlocker invite on the iPhone you want to add to \(lockName). The link does not contain a key; the new iPhone still has to show a 4-digit code that a trusted device approves."
    }

    var activePairingInviteStatus: String? {
        guard let activePairingInvite else { return nil }

        if isPairingThisPhone {
            return "Send this 4-digit code to the trusted device so it can approve access."
        }

        if canPair {
            return "Pairing is open for \(activePairingInvite.lockName). Tap Pair This iPhone if it does not start automatically."
        }

        if isConnectedToController {
            return "Connected to the controller. Waiting for a trusted device to open pairing."
        }

        return "Looking for \(activePairingInvite.lockName). Stay near the controller while the trusted device opens pairing."
    }

    var canPair: Bool {
        isConnectedToController && pairingState == "Pairing enabled" && !hasTrustedPairingForSecureCommand
    }

    var needsUsbPairingMode: Bool {
        isConnectedToController && pairingState == "Pairing locked"
    }

    var isPairingPending: Bool {
        pairingState == "Pairing pending" || pairingState == "Pairing"
    }

    var isPairingThisPhone: Bool {
        pairingApprovalCode != nil && isPairingPending
    }

    var canAdministerPairing: Bool {
        hasTrustedPairingForSecureCommand && (isReady || canQueueControllerSettingForKnownController)
    }

    var canApprovePendingPairing: Bool {
        pairingState == "Pairing pending" && !isPairingThisPhone && canAdministerPairing
    }

    func pairThisPhone() {
        guard let peripheral, let pairingCharacteristic else {
            lastError = "Pairing characteristic not found"
            return
        }

        do {
            let pairingPayload = try DoorCommandAuthenticator.pairingPayload(deviceName: deviceDisplayName)
            let approvalCode = try DoorCommandAuthenticator.pairingApprovalCode()
            guard pairingPayload.count <= peripheral.maximumWriteValueLength(for: .withResponse) else {
                lastError = "Pairing key is too large for this BLE connection"
                return
            }

            lastError = nil
            hasRejectedCurrentSecurePairing = false
            pairingApprovalCode = approvalCode
            pairingState = "Pairing"
            peripheral.writeValue(pairingPayload, for: pairingCharacteristic, type: .withResponse)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func allowNewDevicePairing() {
        sendPairingAdminCommand("PAIR_ON")
    }

    func beginInviteFlow() {
        guard canAdministerPairing else {
            lastError = "This iPhone must be paired before it can invite another device."
            requestControllerConnectionIfNeeded()
            return
        }

        lastError = nil
        if pairingState != "Pairing enabled" {
            allowNewDevicePairing()
        }
    }

    func stopNewDevicePairing() {
        sendPairingAdminCommand("PAIR_OFF")
    }

    func approvePendingPairing() {
        let code = pairingAdminApprovalCode.filter(\.isNumber)
        guard code.count == 4 else {
            lastError = "Enter the 4-digit code shown on the new device."
            return
        }

        sendPairingAdminCommand("PAIR_APPROVE:\(code)")
    }

    func rejectPendingPairing() {
        sendPairingAdminCommand("PAIR_REJECT")
    }

    func sendPairingAdminCommand(_ commandText: String) {
        guard canAdministerPairing else {
            queuedPairingAdminCommand = commandText
            requestControllerConnectionIfNeeded()
            return
        }

        guard fastCommandNonce != nil else {
            queuedPairingAdminCommand = commandText
            requestFreshSecureControlNonce()
            return
        }

        if writeAuthenticatedCommand(commandText, intent: .pairingAdmin(commandText)) {
            queuedPairingAdminCommand = nil
            if commandText.hasPrefix("PAIR_APPROVE:") || commandText == "PAIR_REJECT" {
                pairingAdminApprovalCode = ""
            }
        }
    }

    @discardableResult
    func handlePairingInviteURL(_ url: URL) -> Bool {
        guard url.scheme == "doorunlocker", url.host == "pair" else {
            return false
        }

        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let invitedLockName = items.first { $0.name == "lock" }?.value?.trimmingCharacters(in: .whitespacesAndNewlines)
        let inviterName = items.first { $0.name == "from" }?.value?.trimmingCharacters(in: .whitespacesAndNewlines)

        activePairingInvite = PairingInvite(
            lockName: invitedLockName?.isEmpty == false ? invitedLockName! : lockName,
            inviterName: inviterName?.isEmpty == false ? inviterName : nil
        )
        shouldPairFromInviteWhenReady = true
        lastError = nil

        if hasTrustedPairingForSecureCommand {
            shouldPairFromInviteWhenReady = false
            lastError = "This iPhone already has access to \(lockName)."
            return true
        }

        requestControllerConnectionIfNeeded()
        pairFromInviteIfReady()
        return true
    }

    func pairFromInviteIfReady() {
        guard shouldPairFromInviteWhenReady else { return }

        if hasTrustedPairingForSecureCommand {
            shouldPairFromInviteWhenReady = false
            return
        }

        guard canPair else { return }
        shouldPairFromInviteWhenReady = false
        pairThisPhone()
    }
}
