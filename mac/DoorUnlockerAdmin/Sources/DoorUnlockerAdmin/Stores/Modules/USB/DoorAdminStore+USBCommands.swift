import CoreBluetooth
import DoorUnlockerCore
import DoorUnlockerDFU
import DoorUnlockerShared
import Foundation
import os

extension DoorAdminStore {
    func sendStatusCommand(
        _ command: String,
        label: String,
        timeout: TimeInterval,
        refreshPairsAfterSuccess: Bool = true,
        afterSuccess: (() -> Void)? = nil
    ) {
        guard !isBusy else { return }
        cancelUSBStartupSync()
        Task {
            await run(label) {
                recordRuntimeTelemetry("usb_command_start", details: label, once: false)
                let lines = try await transact(command, until: ["APP_STATUS_END"], timeout: timeout)
                appendLog(lines)
                applyControllerStatus(DoorSerialParser.parseStatus(from: lines))
                message = successMessage(for: label, status: status)
                if refreshPairsAfterSuccess {
                    try await loadPairedDevices()
                }
                afterSuccess?()
                recordRuntimeTelemetry("usb_command_done", details: label, once: false)
            }
        }
    }

    func run(_ label: String, operation: () async throws -> Void) async {
        isBusy = true
        lastError = nil
        message = label
        defer {
            isBusy = false
            if let command = pendingLocalDoorCommand {
                pendingLocalDoorCommand = nil
                sendDoorCommand(command)
            }
        }

        do {
            try await operation()
        } catch {
            if label == "Lock" || label == "Unlock" {
                restorePredictedDoorStateIfNeeded()
            }
            if label == "Auto-lock" {
                inFlightAutoLockSeconds = nil
                if pendingAutoLockSeconds == nil {
                    clearLocalSettingApply("timeout")
                    autoLockStatus = "Not set"
                }
            }
            if label == "Servo angles" {
                inFlightServoAngles = nil
                if pendingServoAngles == nil {
                    clearLocalSettingApply("servo_angles")
                    servoAnglesStatus = "Not set"
                }
            }
            if label == "Firmware update" {
                pendingFirmwareUpdatePackageURL = nil
                firmwareUpdateEntryCommandSent = false
                firmwareUpdateStatus = "Firmware update failed"
                firmwareUpdateProgress = nil
                isFirmwareUpdateRunning = false
            }
            lastError = error.localizedDescription
            message = "Something went wrong"
            appendLog(["ERROR \(error.localizedDescription)"])
        }
    }

    func loadControllerState(statusTimeout: TimeInterval = 4, pairTimeout: TimeInterval = 4) async throws {
        let statusLines = try await transact("app status", until: ["APP_STATUS_END"], timeout: statusTimeout)
        guard DoorSerialParser.isValidControllerStatusResponse(statusLines) else {
            throw DoorAdminError.invalidController
        }
        appendLog(statusLines)
        applyControllerStatus(DoorSerialParser.parseStatus(from: statusLines))
        message = statusMessage(for: status)
        try await loadPairedDevices(timeout: pairTimeout)
    }

    func loadPairedDevices(shouldLog: Bool = true, timeout: TimeInterval = 4) async throws {
        let pairLines = try await transact("app pairs", until: ["APP_PAIRS_END"], timeout: timeout)
        if shouldLog {
            appendLog(pairLines)
        }
        pairedDevices = DoorSerialParser.parsePairs(from: pairLines)
        lastPairedDevicesSyncAt = .now
        var nextStatus = status
        nextStatus.pairedCount = pairedDevices.count
        nextStatus.maxPairs = max(nextStatus.maxPairs, nextStatus.pairedCount, 4)
        status = nextStatus
        saveCachedStatus(nextStatus)

        if let selectedDeviceID, pairedDevices.contains(where: { $0.id == selectedDeviceID }) {
            return
        }

        selectedDeviceID = pairedDevices.first?.id
    }
}
