import DoorUnlockerShared
import Foundation

extension DoorAdminStore {
    func startSecureLinkWatchdogIfNeeded() {
        guard secureLinkWatchdogTask == nil, needsFreshSecureNonce else { return }
        secureLinkWatchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                let action = await MainActor.run { () -> DoorCommandPreparationRecoveryAction in
                    guard let self else { return .idle }
                    return DoorCommandPreparationRecoveryPolicy.action(
                        needsFreshNonce: self.needsFreshSecureNonce,
                        hasQueuedCommand: self.pendingWirelessCommandText != nil || self.pendingFirmwareUpdatePackageURL != nil,
                        completedNonceRequests: self.queuedWirelessCommandNonceRequestCount
                    )
                }

                switch action {
                case .idle:
                    break
                case .requestNonce:
                    await MainActor.run {
                        guard let self, self.needsFreshSecureNonce else { return }
                        if self.pendingWirelessCommandText != nil || self.pendingFirmwareUpdatePackageURL != nil {
                            self.queuedWirelessCommandNonceRequestCount += 1
                        } else {
                            self.queuedWirelessCommandNonceRequestCount = 0
                        }
                        self.requestWirelessControlNonceWithoutWatchdog()
                    }
                case .reconnect:
                    await MainActor.run {
                        self?.recoverStalledQueuedSecureCommandLink()
                    }
                }

                guard action == .requestNonce else { break }
                try? await Task.sleep(for: .milliseconds(500))
            }

            await MainActor.run {
                self?.secureLinkWatchdogTask = nil
            }
        }
    }

    func recoverStalledQueuedSecureCommandLink() {
        guard pendingWirelessCommandText != nil || pendingFirmwareUpdatePackageURL != nil else {
            queuedWirelessCommandNonceRequestCount = 0
            return
        }

        queuedWirelessCommandNonceRequestCount = 0
        recordRuntimeTelemetry("secure_command_link_recovery", once: false)
        lastError = nil
        invalidatePreparedFastDoorCommandPayloads(clearNonce: true)
        resetWirelessLinkAuthentication()
        stopWirelessSession(reason: "Reconnecting")
        scanBluetooth()
    }

    func scheduleWirelessDoorCommandTransportRecovery() {
        guard wirelessDoorCommandTransportRecoveryTask == nil else { return }
        wirelessDoorCommandTransportRecoveryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            await MainActor.run {
                guard let self else { return }
                self.wirelessDoorCommandTransportRecoveryTask = nil
                guard self.pendingWirelessPredictedCommand != nil else { return }
                if self.peripheral?.canSendWriteWithoutResponse == true {
                    self.sendQueuedWirelessCommand()
                } else {
                    self.stopWirelessSession(reason: "Reconnecting")
                    self.scanBluetooth()
                }
            }
        }
    }

    func stopWirelessDoorCommandTransportRecovery() {
        wirelessDoorCommandTransportRecoveryTask?.cancel()
        wirelessDoorCommandTransportRecoveryTask = nil
    }

    func scheduleWirelessDoorCommandConfirmation(_ command: Command) {
        wirelessDoorCommandConfirmationTask?.cancel()
        wirelessDoorCommandConfirmationTask = Task { [weak self] in
            let readDelays: [UInt64] = [250_000_000, 500_000_000, 1_000_000_000]
            for delay in readDelays {
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled else { return }
                let isPending = await MainActor.run {
                    guard let self, self.fastDoorCommandInFlight == command else { return false }
                    self.readStateIfPossible()
                    return true
                }
                guard isPending else { return }
            }
            await MainActor.run {
                guard let self, self.fastDoorCommandInFlight == command else { return }
                self.fastDoorCommandInFlight = nil
                self.wirelessDoorCommandConfirmationTask = nil
                let action = command == .unlock ? "unlock" : "lock"
                self.lastError = "Controller did not confirm \(action)."
            }
        }
    }

    func stopWirelessDoorCommandConfirmation() {
        wirelessDoorCommandConfirmationTask?.cancel()
        wirelessDoorCommandConfirmationTask = nil
    }

    func reconcileWirelessDoorCommands(with state: String) {
        if let pendingCommand = pendingWirelessPredictedCommand,
           DoorControlPresentationPolicy.state(
                state,
                satisfiesUnlockedTarget: pendingCommand == .unlock
           ) {
            clearPendingWirelessCommandIfMatchingDoorCommand(pendingCommand)
        }

        if let inFlightCommand = fastDoorCommandInFlight,
           DoorControlPresentationPolicy.state(
                state,
                satisfiesUnlockedTarget: inFlightCommand == .unlock
           ) {
            fastDoorCommandInFlight = nil
            stopWirelessDoorCommandConfirmation()
            lastError = nil
        }
    }
}
