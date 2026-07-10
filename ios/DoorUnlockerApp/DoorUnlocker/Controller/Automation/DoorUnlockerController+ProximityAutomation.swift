import CoreBluetooth
import CoreLocation
import DoorUnlockerDFU
import DoorUnlockerShared
import Foundation
import ActivityKit
import LocalAuthentication
import UIKit
import UserNotifications
import WidgetKit

extension DoorUnlockerController {
    func runSystemCommand(_ systemCommand: DoorSystemCommand) {
        switch systemCommand {
        case .lock:
            if !send(.lock) {
                pendingSystemCommand = systemCommand
                requestControllerConnectionIfNeeded()
            }
        case .unlock:
            if !send(.unlock) {
                pendingSystemCommand = systemCommand
                requestControllerConnectionIfNeeded()
            }
        case .toggle:
            guard hasKnownLockState else {
                pendingSystemCommand = systemCommand
                _ = readStateIfPermitted()
                requestControllerConnectionIfNeeded()
                return
            }

            toggleLock()
        }
    }

    func beginProximityUnlockAwayCheck() {
        guard proximityUnlockEnabled, proximityUnlockArmedAt == nil else {
            updateProximityUnlockStatus()
            return
        }

        guard central?.state == .poweredOn else {
            clearProximityUnlockArming()
            updateProximityUnlockStatus()
            return
        }

        beginProximityUnlockBackgroundTask()
        proximityUnlockCandidateStartedAt = Date()
        proximityUnlockArmTask?.cancel()
        updateProximityUnlockStatus()
        confirmProximityUnlockAwayCheck()
    }

    func confirmProximityUnlockAwayCheck() {
        proximityUnlockArmTask = nil

        guard proximityUnlockEnabled,
              proximityUnlockCandidateStartedAt != nil,
              central?.state == .poweredOn,
              !isReady else {
            clearProximityUnlockArming()
            updateProximityUnlockStatus()
            return
        }

        guard let startedAt = proximityUnlockCandidateStartedAt else {
            clearProximityUnlockArming()
            updateProximityUnlockStatus()
            return
        }

        guard lockZoneCenter != nil else {
            armProximityUnlockIfCandidateStillCurrent(startedAt: startedAt)
            return
        }

        if isKnownOutsideLockZone {
            armProximityUnlockIfCandidateStillCurrent(startedAt: startedAt)
            return
        }

        lockZoneStatus = "Checking zone"
        proximityUnlockStatus = "Zone check"
        requestCurrentLocation(for: .proximityArmCheck(startedAt))
    }

    func armProximityUnlockIfCandidateStillCurrent(startedAt: Date) {
        guard proximityUnlockEnabled,
              proximityUnlockCandidateStartedAt == startedAt,
              central?.state == .poweredOn,
              !isReady else {
            clearProximityUnlockArming()
            updateProximityUnlockStatus()
            return
        }

        proximityUnlockCandidateStartedAt = nil
        setProximityUnlockArmed()
        updateProximityUnlockStatus()
    }

    func armProximityUnlockIfOutsideAndDisconnected() {
        guard proximityUnlockEnabled,
              lockZoneCenter != nil,
              isKnownOutsideLockZone,
              proximityUnlockArmedAt == nil,
              !isReady,
              hasKnownController,
              hasTrustedPairingForSecureCommand else {
            updateProximityUnlockStatus()
            return
        }

        clearProximityUnlockCandidate()
        setProximityUnlockArmed()
        updateProximityUnlockStatus()
    }

    func setProximityUnlockArmed() {
        let wasAlreadyArmed = proximityUnlockArmedAt != nil
        let armedAt = Date()
        beginProximityUnlockBackgroundTask()
        proximityUnlockArmedAt = armedAt
        UserDefaults.standard.set(armedAt.timeIntervalSince1970, forKey: Self.proximityUnlockArmedAtKey)
        accelerateProximityUnlockReconnectIfNeeded()
        if !wasAlreadyArmed {
            notifyProximityUnlockArmedIfNeeded()
        }
    }

    func restoreProximityUnlockAfterInterruptedCommand() {
        guard proximityUnlockEnabled,
              lockZoneCenter != nil,
              proximityUnlockArmedAt == nil else {
            updateProximityUnlockStatus()
            return
        }

        clearProximityUnlockCandidate()
        setProximityUnlockArmed()
        proximityUnlockStatus = "Retrying"
        scheduleReconnectCheck(after: Self.fastKnownControllerRetryDelay)
    }

    func clearProximityUnlockCandidate() {
        proximityUnlockArmTask?.cancel()
        proximityUnlockArmTask = nil
        proximityUnlockCandidateStartedAt = nil
    }

    func clearProximityUnlockCandidateIfUnarmed() {
        guard proximityUnlockArmedAt == nil else { return }
        clearProximityUnlockCandidate()
    }

    func clearProximityUnlockArming() {
        let hasPendingProximityCommand = optimisticDoorCommandOrigin == .proximity
            || pendingFreshNonceDoorCommand?.origin == .proximity
        clearProximityUnlockCandidate()
        proximityUnlockArmedAt = nil
        UserDefaults.standard.removeObject(forKey: Self.proximityUnlockArmedAtKey)
        if !hasPendingProximityCommand {
            endProximityUnlockBackgroundTask()
        }
    }

    func updateProximityUnlockStatus() {
        guard proximityUnlockEnabled else {
            proximityUnlockStatus = "Off"
            return
        }

        if proximityUnlockArmedAt != nil {
            if lockZoneBluetoothRSSI == nil {
                proximityUnlockStatus = "Reading signal"
            } else if !isProximityUnlockRSSIGateSatisfied {
                proximityUnlockStatus = "Signal weak"
            } else {
                proximityUnlockStatus = "Armed"
            }
        } else if proximityUnlockCandidateStartedAt != nil {
            proximityUnlockStatus = "Checking away"
        } else if isReady {
            proximityUnlockStatus = isKnownOutsideLockZone ? "Left zone" : "Monitoring"
        } else if bluetoothState != "On" {
            proximityUnlockStatus = bluetoothState
        } else {
            proximityUnlockStatus = isKnownOutsideLockZone ? "Away" : "Waiting"
        }
    }
}
