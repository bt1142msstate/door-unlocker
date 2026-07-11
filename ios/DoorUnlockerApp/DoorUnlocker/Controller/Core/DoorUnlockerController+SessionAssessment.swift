import CoreBluetooth
import DoorUnlockerShared

extension DoorUnlockerController {
    var sessionAssessment: DoorControllerSessionAssessment {
        DoorControllerSessionAssessment.assess(
            DoorControllerSessionFacts(
                bluetooth: assessedBluetoothAvailability,
                link: assessedLinkPhase,
                isTransportConnected: peripheral?.state == .connected,
                isGattReady: hasDiscoveredControllerCharacteristics,
                isTrusted: hasTrustedPairingForSecureCommand,
                isControllerHealthKnown: controllerHealthStatus != "unknown",
                isControllerHealthy: controllerHealthStatus == "ok",
                isLinkAuthenticated: hasAuthenticatedCurrentLink,
                hasCurrentStateSnapshot: hasCurrentControllerSnapshot,
                hasFreshCommandMaterial: hasFreshFastCommandMaterial,
                canQueueCommand: canQueueDoorCommandForKnownController
            )
        )
    }

    func applyControllerBootSession(_ identifier: String) {
        guard controllerFreshness.receiveBootSession(identifier) else { return }
        completeRestoredConnectionValidation()
        hasCurrentFirmwareVersionSnapshot = false
        mirrorControllerFreshness()
#if DEBUG
        recordStartupTelemetry("controller_session_received", details: identifier, once: false)
#endif
        controllerSessionGeneration &+= 1
        if optimisticDoorCommand != nil || pendingFreshNonceDoorCommand != nil {
            let restoredState = stableRestoredDoorState()
            clearOptimisticDoorCommand()
            servoState = restoredState
        }
        requeueControllerSettingAfterSessionInterruption()
        refreshControllerMetadataSnapshotRetry()
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
        refreshControllerMetadataSnapshotRetry()
        refreshDoorCommandDispatchReadiness()
        return true
    }

    @discardableResult
    func markControllerStateSnapshotCurrent() -> Bool {
        guard controllerFreshness.receiveStateSnapshot() else { return false }
        mirrorControllerFreshness()
        refreshControllerMetadataSnapshotRetry()
        refreshDoorCommandDispatchReadiness()
        return true
    }

    @discardableResult
    func markControllerConnectionRosterCurrent() -> Bool {
        guard controllerFreshness.receiveConnectionRoster() else {
#if DEBUG
            recordStartupTelemetry("controller_roster_deferred", details: "missing_session", once: false)
#endif
            scheduleStateSnapshotFallbackRead(delay: .milliseconds(350))
            return false
        }
        mirrorControllerFreshness()
        refreshControllerMetadataSnapshotRetry()
        return true
    }

    private func mirrorControllerFreshness() {
        controllerBootSessionIdentifier = controllerFreshness.bootSessionIdentifier
        controllerHealthStatus = controllerFreshness.storageHealth.rawValue
        hasCurrentControllerSnapshot = controllerFreshness.hasCurrentStateSnapshot
        hasCurrentConnectionRoster = controllerFreshness.hasCurrentConnectionRoster
    }

    func refreshDoorCommandDispatchReadiness() {
        guard canAcceptDoorCommand else { return }
#if DEBUG
        recordStartupTelemetry("door_command_dispatch_ready")
        recordWarmLaunchReadinessIfPossible()
#endif
    }

    var hasCurrentCriticalStartupSnapshot: Bool {
        controllerBootSessionIdentifier != nil &&
            controllerHealthStatus != "unknown" &&
            hasCurrentControllerSnapshot
    }

    func finishCriticalStartupSnapshotIfCurrent() {
        guard hasCurrentCriticalStartupSnapshot else { return }
        startupCriticalSnapshotTask?.cancel()
        startupCriticalSnapshotTask = nil
    }

    var isControllerOnline: Bool {
        sessionAssessment.isControllerOnline
    }

    var isDisplayedControllerStateAuthoritative: Bool {
        sessionAssessment.isDisplayedStateAuthoritative
    }

    private var assessedBluetoothAvailability: DoorBluetoothAvailability {
        switch bluetoothState {
        case "On":
            return .available
        case "Off":
            return .poweredOff
        case "Unauthorized":
            return .unauthorized
        case "Unsupported":
            return .unsupported
        case "Resetting":
            return .resetting
        case "Starting":
            return .starting
        default:
            return .unknown
        }
    }

    private var assessedLinkPhase: DoorControllerLinkPhase {
        if isFirmwareDfuTransportActive || connectionState == "Updating firmware" {
            return .updatingFirmware
        }

        switch connectionState {
        case "Scanning", "Known controller":
            return .scanning
        case "Connecting", "Reconnecting":
            return .connecting
        case "Discovering", "Ready":
            return peripheral?.state == .connected ? .connected : .discovering
        case "Restoring":
            return .restoring
        default:
            return peripheral?.state == .connected ? .connected : .idle
        }
    }
}
