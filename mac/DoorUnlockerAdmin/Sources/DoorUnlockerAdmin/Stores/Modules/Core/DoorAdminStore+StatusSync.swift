import CoreBluetooth
import DoorUnlockerCore
import DoorUnlockerDFU
import DoorUnlockerShared
import Foundation
import os

extension DoorAdminStore {
    func syncControllerStateIfNeeded() async {
        refreshUSBPortsIfNeeded()

        let shouldConfirmExpiredAutoLock = updateLocalAutoLockCountdown()

        if isConnected, !isBusy {
            let now = Date()
            let isUSBPollDue = lastUSBStatusSyncAt.map { now.timeIntervalSince($0) >= 2 } ?? true
            let shouldPollUSB = shouldConfirmExpiredAutoLock || isUSBPollDue
            if shouldPollUSB {
                lastUSBStatusSyncAt = now
                if shouldConfirmExpiredAutoLock {
                    hasConfirmedExpiredAutoLockDeadline = true
                }
                await silentlySyncUSBStatus()
            }

            await syncPairedDevicesIfNeeded(now: now)
            return
        }

        guard central?.state == .poweredOn, canUseWirelessFallback else { return }

        if !isWirelessSessionActive {
            return
        }

        guard isWirelessGattReady else { return }

        if isWirelessStateNotificationEnabled {
            guard shouldConfirmExpiredAutoLock else { return }
            lastWirelessStateSyncAt = Date()
            hasConfirmedExpiredAutoLockDeadline = true
            readStateIfPossible()
            return
        }

        let now = Date()
        let isWirelessPollDue = lastWirelessStateSyncAt.map { now.timeIntervalSince($0) >= Self.wirelessStatePollInterval } ?? true
        guard shouldConfirmExpiredAutoLock || isWirelessPollDue else { return }

        lastWirelessStateSyncAt = now
        if shouldConfirmExpiredAutoLock {
            hasConfirmedExpiredAutoLockDeadline = true
        }
        readStateIfPossible()
    }

    func updateLocalAutoLockCountdown() -> Bool {
        guard status.isUnlocked, let deadline = status.autoLockDeadline else {
            return false
        }

        let remainingSeconds = Int(ceil(deadline.timeIntervalSinceNow))
        if remainingSeconds > 0 {
            if status.autoLockRemainingSeconds != remainingSeconds {
                var nextStatus = status
                nextStatus.autoLockRemainingSeconds = remainingSeconds
                status = nextStatus
            }
            return false
        }

        var nextStatus = status
        nextStatus.bleState = "locked"
        nextStatus.isUnlocked = false
        nextStatus.autoLockRemainingSeconds = nil
        nextStatus.autoLockDeadline = nil
        status = nextStatus
        saveCachedStatus(nextStatus)
        message = "Door locked"
        return !hasConfirmedExpiredAutoLockDeadline
    }

    func silentlySyncUSBStatus() async {
        guard !isSilentStatusSyncInFlight else { return }
        isSilentStatusSyncInFlight = true
        defer { isSilentStatusSyncInFlight = false }

        do {
            let statusLines = try await transact("app status", until: ["APP_STATUS_END"], timeout: 2)
            let nextStatus = DoorSerialParser.parseStatus(from: statusLines)
            if nextStatus != status {
                applyControllerStatus(nextStatus)
                message = statusMessage(for: nextStatus)
            }
        } catch {
            guard isConnected else { return }
            if !selectedUSBPortStillPresent() {
                markUSBDisconnected(reason: "USB-C disconnected")
                return
            }
            lastError = error.localizedDescription
        }
    }

    func syncPairedDevicesIfNeeded(now: Date) async {
        let isPairCountStale = status.pairedCount != pairedDevices.count
        let secondsSinceLastSync = lastPairedDevicesSyncAt.map { now.timeIntervalSince($0) }
        let isPairListDue = secondsSinceLastSync.map { $0 >= Self.pairedDevicesSyncInterval } ?? true
        let canForceSyncForCountChange = isPairCountStale && (secondsSinceLastSync.map { $0 >= 1 } ?? true)

        guard canForceSyncForCountChange || isPairListDue else { return }

        do {
            try await loadPairedDevices(shouldLog: false)
        } catch {
            guard isConnected else { return }
            lastPairedDevicesSyncAt = now
            lastError = error.localizedDescription
        }
    }

    func successMessage(for label: String, status: ControllerStatus) -> String {
        switch label {
        case "Lock":
            return "Door locked"
        case "Unlock":
            return "Door unlocked"
        case "Allow New Device":
            return "Ready to add a device"
        case "Stop Pairing":
            return "Pairing closed"
        case "Approve Device":
            return "Device trusted"
        case "Reject Device":
            return "Pairing request rejected"
        case "Remove Device":
            return "Device removed"
        case "Clear Devices":
            return "Trusted devices cleared"
        case "Rename Device":
            return "Device renamed"
        case "Auto-lock":
            return "Auto-lock updated"
        case "Servo angles":
            return "Servo angles updated"
        default:
            return statusMessage(for: status)
        }
    }

    func statusMessage(for status: ControllerStatus) -> String {
        if status.hasPendingRequest {
            return "Device waiting for approval"
        }

        switch status.bleState {
        case "unlocked", "unlocking":
            return "Door unlocked"
        case "locked", "locking":
            return "Door locked"
        case "pairing_enabled":
            return "Ready to add a device"
        case "pairing_pending":
            return "Device waiting for approval"
        case "pairing_locked":
            return "Pairing closed"
        default:
            return isConnected ? "Controller ready" : "Disconnected"
        }
    }

    static func cachedStartupMessage() -> String {
        let status = loadCachedStatus()
        if status.hasPendingRequest {
            return "Device waiting for approval"
        }

        switch status.bleState {
        case "unlocked", "unlocking":
            return "Door unlocked"
        case "locked", "locking":
            return "Door locked"
        case "pairing_enabled":
            return "Ready to add a device"
        case "pairing_pending":
            return "Device waiting for approval"
        case "pairing_locked":
            return "Pairing closed"
        default:
            let hasTrustedController = UserDefaults.standard.bool(forKey: trustedMacControllerKey)
            let hasKnownController = UserDefaults.standard.string(forKey: knownPeripheralIdentifierKey) != nil
            return hasTrustedController && hasKnownController ? "Opening saved controller" : "Disconnected"
        }
    }

    func transact(_ command: String, until markers: Set<String>, timeout: TimeInterval) async throws -> [String] {
        guard let connection else { throw DoorAdminError.notConnected }
        return try await serialGate.transact(connection: connection, command: command, until: markers, timeout: timeout)
    }

    func appendLog(_ lines: [String]) {
        logLines.append(contentsOf: lines.map(redactedLogLine))
        if logLines.count > 120 {
            logLines.removeFirst(logLines.count - 120)
        }
    }

    func redactedLogLine(_ line: String) -> String {
        let sensitivePrefixes = [
            "Code:",
            "Fingerprint:",
            "Expected code:",
            "Expected fingerprint:",
            "pending_fingerprint="
        ]

        if sensitivePrefixes.contains(where: { line.hasPrefix($0) }) {
            return "[pairing confirmation hidden]"
        }
        return line
    }
}
