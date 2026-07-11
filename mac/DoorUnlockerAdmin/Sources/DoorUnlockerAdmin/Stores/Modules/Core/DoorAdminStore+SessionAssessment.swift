import CoreBluetooth
import DoorUnlockerShared

extension DoorAdminStore {
    var sessionAssessment: DoorControllerSessionAssessment {
        if isUSBControllerValidated {
            return DoorControllerSessionAssessment.assess(
                DoorControllerSessionFacts(
                    bluetooth: .available,
                    link: .connected,
                    isTransportConnected: true,
                    isGattReady: true,
                    isTrusted: true,
                    isControllerHealthKnown: controllerHealthStatus != "unknown",
                    isControllerHealthy: controllerHealthStatus == "ok",
                    isLinkAuthenticated: true,
                    hasCurrentStateSnapshot: hasCurrentControllerSnapshot,
                    hasFreshCommandMaterial: true
                )
            )
        }

        return DoorControllerSessionAssessment.assess(
            DoorControllerSessionFacts(
                bluetooth: assessedBluetoothAvailability,
                link: assessedWirelessLinkPhase,
                isTransportConnected: peripheral?.state == .connected,
                isGattReady: isWirelessGattReady,
                isTrusted: hasTrustedWirelessPairingForSecureCommand,
                isControllerHealthKnown: controllerHealthStatus != "unknown",
                isControllerHealthy: controllerHealthStatus == "ok",
                isLinkAuthenticated: hasAuthenticatedCurrentWirelessLink,
                hasCurrentStateSnapshot: hasCurrentControllerSnapshot,
                hasFreshCommandMaterial: hasFreshFastCommandMaterial,
                canQueueCommand: canQueueWirelessCommandForKnownController
            )
        )
    }

    func applyControllerBootSession(_ identifier: String) {
        guard controllerFreshness.receiveBootSession(identifier) else { return }
        hasCurrentFirmwareVersionSnapshot = false
        mirrorControllerFreshness()
        recordRuntimeTelemetry("controller_session_received", details: identifier, once: false)
        restorePredictedDoorStateIfNeeded()
        requeueInterruptedWirelessSettingIfNeeded()
        refreshWirelessControllerMetadataSnapshotRetry()
    }

    func invalidateControllerFreshness() {
        controllerFreshness.invalidateTransport()
        hasCurrentFirmwareVersionSnapshot = false
        mirrorControllerFreshness()
    }

    @discardableResult
    func applyControllerStorageHealth(_ value: String) -> Bool {
        guard controllerFreshness.receiveStorageHealth(value) else { return false }
        mirrorControllerFreshness()
        refreshWirelessControllerMetadataSnapshotRetry()
        return true
    }

    @discardableResult
    func markControllerStateSnapshotCurrent() -> Bool {
        guard controllerFreshness.receiveStateSnapshot() else { return false }
        mirrorControllerFreshness()
        refreshWirelessControllerMetadataSnapshotRetry()
        return true
    }

    @discardableResult
    func markControllerConnectionRosterCurrent() -> Bool {
        guard controllerFreshness.receiveConnectionRoster() else {
            recordRuntimeTelemetry("controller_roster_deferred", details: "missing_session", once: false)
            scheduleWirelessStateSnapshotFallbackRead(after: 0.35)
            return false
        }
        mirrorControllerFreshness()
        refreshWirelessControllerMetadataSnapshotRetry()
        return true
    }

    private func mirrorControllerFreshness() {
        controllerBootSessionIdentifier = controllerFreshness.bootSessionIdentifier
        controllerHealthStatus = controllerFreshness.storageHealth.rawValue
        hasCurrentControllerSnapshot = controllerFreshness.hasCurrentStateSnapshot
        hasCurrentConnectionRoster = controllerFreshness.hasCurrentConnectionRoster
    }

    var isDisplayedControllerStateAuthoritative: Bool {
        sessionAssessment.isDisplayedStateAuthoritative
    }

    private var assessedBluetoothAvailability: DoorBluetoothAvailability {
        switch bluetoothState {
        case "On": return .available
        case "Off": return .poweredOff
        case "Unauthorized": return .unauthorized
        case "Unsupported": return .unsupported
        case "Resetting": return .resetting
        case "Starting": return .starting
        default: return .unknown
        }
    }

    private var assessedWirelessLinkPhase: DoorControllerLinkPhase {
        if isFirmwareUpdateRunning || wirelessConnectionState == "Updating firmware" {
            return .updatingFirmware
        }

        switch wirelessConnectionState {
        case "Scanning", "Connecting on demand": return .scanning
        case "Connecting", "Reconnecting", "Wireless resyncing": return .connecting
        case "Discovering", "Ready":
            return peripheral?.state == .connected ? .connected : .discovering
        case "Restoring": return .restoring
        default: return peripheral?.state == .connected ? .connected : .idle
        }
    }
}
