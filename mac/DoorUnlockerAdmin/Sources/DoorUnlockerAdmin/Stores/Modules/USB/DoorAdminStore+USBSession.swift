import CoreBluetooth
import DoorUnlockerCore
import DoorUnlockerDFU
import DoorUnlockerShared
import Foundation
import os

extension DoorAdminStore {
    func connectToSelectedPort(allowScheduledStart: Bool = false) async {
        guard allowScheduledStart || !isUSBConnectInFlight else { return }

        isUSBConnectInFlight = true
        lastError = nil
        message = "Opening USB-C"

        do {
            guard let selectedPort else { throw DoorAdminError.noPortSelected }

            cancelUSBStartupSync()
            connection?.close()
            connection = try SerialPortConnection(path: selectedPort.path)
            isConnected = true
            isUSBControllerValidated = false
            isUSBConnectInFlight = false
            lastUSBStatusSyncAt = .now
            lastPairedDevicesSyncAt = .now
            lastUSBDiscoveryAt = nil
            didTrustMacDuringUSBSession = false
            message = "Validating USB-C controller"
            recordRuntimeTelemetry("usb_opened", details: selectedPort.displayName)
            stopWirelessSession(reason: "USB-C active")
            usbStartupSyncTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: Self.usbStartupSyncGraceNanoseconds)
                guard !Task.isCancelled else { return }
                await self?.finishUSBStartupSync()
            }
        } catch {
            isUSBConnectInFlight = false
            connection?.close()
            connection = nil
            isConnected = false
            isUSBControllerValidated = false
            lastError = error.localizedDescription
            message = "USB-C unavailable"
            ensureBluetoothCentral()
            if central?.state == .poweredOn, canUseWirelessFallback {
                scanBluetooth()
            }
        }
    }

    func finishUSBStartupSync() async {
        guard isConnected else { return }
        defer { usbStartupSyncTask = nil }
        recordRuntimeTelemetry("usb_startup_sync_start")

        do {
            do {
                try await loadControllerState(statusTimeout: 0.8, pairTimeout: 0.8)
            } catch {
                guard !Task.isCancelled else { return }
                try await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
                try await loadControllerState(statusTimeout: 2, pairTimeout: 2)
            }
            guard !Task.isCancelled else { return }
            isUSBControllerValidated = true
            lastControllerActivityAt = .now
            status = statusIncludingLocalUSBConnection(status)
            message = "USB-C ready"
            recordRuntimeTelemetry("usb_ready")
            lastUSBStatusSyncAt = .now
            try await trustThisMacOverUSBIfNeeded()
            guard !Task.isCancelled else { return }
            await applyPendingAutoLockSeconds()
            await applyPendingServoAngles()
            await applyPendingLockName()
            recordRuntimeTelemetry("usb_startup_sync_done")
        } catch {
            guard isConnected else { return }
            if !selectedUSBPortStillPresent() {
                markUSBDisconnected(reason: "USB-C disconnected")
                return
            }

            connection?.close()
            connection = nil
            isConnected = false
            isUSBControllerValidated = false
            invalidateControllerFreshness()
            lastError = "The USB device did not identify as a Door Unlocker controller: \(error.localizedDescription)"
            message = "USB-C controller not found"
            ensureBluetoothCentral()
            if central?.state == .poweredOn, canUseWirelessFallback {
                scanBluetooth()
            }
        }
    }

    func cancelUSBStartupSync() {
        usbStartupSyncTask?.cancel()
        usbStartupSyncTask = nil
    }

    func autoConnectUSBIfAvailable() {
        guard selectedPort != nil,
              !isConnected,
              !isBusy,
              !isFirmwareUpdateRunning,
              !isUSBConnectInFlight else { return }

        isUSBConnectInFlight = true
        message = "Opening USB-C"
        recordRuntimeTelemetry("usb_auto_connect_start")
        stopWirelessSession(reason: "USB-C active")
        Task { await connectToSelectedPort(allowScheduledStart: true) }
    }

    func markUSBDisconnected(reason: String) {
        cancelUSBStartupSync()
        connection?.close()
        connection = nil
        isConnected = false
        isUSBControllerValidated = false
        isUSBConnectInFlight = false
        lastUSBStatusSyncAt = nil
        didTrustMacDuringUSBSession = false
        invalidateControllerFreshness()
        lastControllerActivityAt = nil
        status = statusRemovingLocalUSBConnection(status)
        message = reason

        ensureBluetoothCentral()
        if central?.state == .poweredOn, canUseWirelessFallback {
            scanBluetooth()
        } else {
            stopWirelessSession(reason: "Idle")
        }
    }

    func selectedUSBPortStillPresent() -> Bool {
        guard let selectedPortID else { return false }
        return SerialPortDiscovery.discover().contains { $0.id == selectedPortID }
    }

    func refreshUSBPortsIfNeeded() {
        guard !isConnected, !isBusy, !isUSBConnectInFlight else { return }

        let now = Date()
        guard lastUSBDiscoveryAt.map({ now.timeIntervalSince($0) >= 2 }) ?? true else { return }

        lastUSBDiscoveryAt = now
        refreshPorts()
    }

    func trustThisMacOverUSBIfNeeded() async throws {
        guard isUSBControllerValidated, !didTrustMacDuringUSBSession else { return }

        let deviceName = localMacDeviceName
        if hasTrustedMacController,
           status.pairedCount > 0,
           pairedDevices.contains(where: { Self.deviceName($0.displayName, matches: deviceName) }) {
            setTrustedMacController(true)
            didTrustMacDuringUSBSession = true
            message = "USB-C ready"
            return
        }

        let payloadHex = try DoorCommandAuthenticator.pairingPayloadHex(deviceName: deviceName)
        let lines = try await transact("app pair usb \(payloadHex)", until: ["APP_STATUS_END"], timeout: 5)
        appendLog(lines)
        applyControllerStatus(DoorSerialParser.parseStatus(from: lines))
        try await loadPairedDevices()

        if let errorLine = lines.first(where: { $0.hasPrefix("APP_ERROR") }) {
            lastError = "Could not trust this Mac automatically: \(errorLine)"
        } else {
            setTrustedMacController(true)
            didTrustMacDuringUSBSession = true
            message = "USB-C ready"
        }
    }

    static func deviceName(_ candidate: String, matches expected: String) -> Bool {
        let normalizedCandidate = DoorDeviceNameNormalizer.normalized(candidate, fallback: "")
        let normalizedExpected = DoorDeviceNameNormalizer.normalized(expected, fallback: "")
        guard !normalizedCandidate.isEmpty, !normalizedExpected.isEmpty else { return false }
        return normalizedCandidate == normalizedExpected
    }

    func setTrustedMacController(_ isTrusted: Bool) {
        hasTrustedMacController = isTrusted
        UserDefaults.standard.set(isTrusted, forKey: Self.trustedMacControllerKey)
        if isTrusted {
            hasRejectedCurrentSecurePairing = false
            let cachedCount = UserDefaults.standard.object(forKey: Self.cachedPairedCountKey) == nil
                ? 0
                : UserDefaults.standard.integer(forKey: Self.cachedPairedCountKey)
            UserDefaults.standard.set(max(cachedCount, 1), forKey: Self.cachedPairedCountKey)
            var nextStatus = status
            nextStatus.pairedCount = max(nextStatus.pairedCount, 1)
            nextStatus.maxPairs = max(nextStatus.maxPairs, 4)
            status = nextStatus
            saveCachedStatus(nextStatus)
        }
    }
}
