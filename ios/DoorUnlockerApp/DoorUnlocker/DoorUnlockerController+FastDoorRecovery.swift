import DoorUnlockerShared
import Foundation

extension DoorUnlockerController {
    func scheduleDoorCommandTransportRecovery() {
        guard doorCommandTransportRecoveryTask == nil else { return }
        doorCommandTransportRecoveryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            await MainActor.run {
                guard let self else { return }
                self.doorCommandTransportRecoveryTask = nil
                guard self.pendingFreshNonceDoorCommand != nil else { return }
                if self.peripheral?.canSendWriteWithoutResponse == true,
                   self.sendPendingFreshNonceDoorCommandIfReady() {
                    return
                }
                self.recoverStalledQueuedDoorCommandLink()
            }
        }
    }

    func stopDoorCommandTransportRecovery() {
        doorCommandTransportRecoveryTask?.cancel()
        doorCommandTransportRecoveryTask = nil
    }

    func clearQueuedDoorCommandIfSatisfied(by state: String) {
        guard let pendingFreshNonceDoorCommand,
              DoorControlPresentationPolicy.state(
                state,
                satisfiesUnlockedTarget: pendingFreshNonceDoorCommand.command == .unlock
              ) else {
            return
        }

        stopDoorCommandTransportRecovery()
        self.pendingFreshNonceDoorCommand = nil
        queuedDoorCommandNonceRequestCount = 0
        lastError = nil
    }
}
