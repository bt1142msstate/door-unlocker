import DoorUnlockerCore
import Foundation

extension DoorAdminStore {
    func enablePairingMode() {
        if sendWirelessPairingAdminCommand("PAIR_ON") {
            return
        }
        sendStatusCommand("app pair on", label: "Allow New Device", timeout: 4)
    }

    func disablePairingMode() {
        if sendWirelessPairingAdminCommand("PAIR_OFF") {
            return
        }
        sendStatusCommand("app pair off", label: "Stop Pairing", timeout: 4)
    }

    func approvePairing() {
        let code = approvalCode.filter(\.isNumber)
        guard code.count == 4 else {
            lastError = "Enter the 4-digit code shown on the device."
            return
        }

        if sendWirelessPairingAdminCommand("PAIR_APPROVE:\(code)") {
            approvalCode = ""
            return
        }

        sendStatusCommand("app approve \(code)", label: "Approve Device", timeout: 5) { [weak self] in
            self?.approvalCode = ""
        }
    }

    func rejectPairing() {
        if sendWirelessPairingAdminCommand("PAIR_REJECT") {
            return
        }
        sendStatusCommand("app reject", label: "Reject Device", timeout: 4)
    }

    @discardableResult
    private func sendWirelessPairingAdminCommand(_ commandText: String) -> Bool {
        guard !isConnected, isWirelessReady || canUseWirelessFallback else {
            return false
        }

        return sendWirelessCommandText(commandText, intent: .pairingAdmin)
    }

    func removeSelectedDevice() {
        guard let selectedDevice else {
            lastError = DoorAdminError.noDeviceSelected.localizedDescription
            return
        }

        sendStatusCommand("app remove \(selectedDevice.slot)", label: "Remove Device", timeout: 4)
    }

    func clearAllDevices() {
        sendStatusCommand("app clear pairs", label: "Clear Devices", timeout: 4)
    }

    func renameSelectedDevice(to name: String) {
        guard let selectedDevice else {
            lastError = DoorAdminError.noDeviceSelected.localizedDescription
            return
        }

        let deviceName = DoorDeviceNameNormalizer.normalized(name, fallback: "")
        guard !deviceName.isEmpty else {
            lastError = "Enter a device name."
            return
        }

        sendStatusCommand("app rename \(selectedDevice.slot) \(deviceName)", label: "Rename Device", timeout: 4)
    }
}
