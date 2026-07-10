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
    func scheduleAutoLockPrediction(deadline: Date?) {
        autoLockPredictionTask?.cancel()

        guard let deadline else {
            autoLockRemainingSeconds = nil
            return
        }

        updateAutoLockRemaining(deadline: deadline)

        autoLockPredictionTask = Task { [weak self] in
            while !Task.isCancelled {
                await MainActor.run {
                    self?.updateAutoLockRemaining(deadline: deadline)
                }

                let remaining = deadline.timeIntervalSinceNow
                if remaining <= 0 {
                    break
                }

                let sleepSeconds = min(1, max(0.1, remaining))
                try? await Task.sleep(nanoseconds: UInt64(sleepSeconds * 1_000_000_000))
            }

            await MainActor.run {
                if !Task.isCancelled {
                    self?.applyPredictedAutoLock(deadline: deadline)
                }
            }
        }
    }

    func updateAutoLockRemaining(deadline: Date) {
        guard isUnlocked else {
            autoLockRemainingSeconds = nil
            return
        }

        autoLockRemainingSeconds = max(0, Int(ceil(deadline.timeIntervalSinceNow)))
    }

    func applyPredictedAutoLock(deadline: Date) {
        guard isUnlocked else { return }

        servoState = "locked"
        autoLockRemainingSeconds = nil
        updatePairingState(from: "locked")
        publishWidgetState("locked", updatedAt: deadline)
        _ = readStateIfPermitted()
    }

    func reconcilePredictedAutoLock() {
        let snapshot = DoorStatusStore.load()
        guard isUnlocked, snapshot.state == "locked" else { return }

        servoState = "locked"
        autoLockRemainingSeconds = nil
        updatePairingState(from: "locked")
        publishWidgetState("locked", updatedAt: snapshot.updatedAt ?? .now)
    }

    func dismissStoredLockedLiveActivityIfNeeded() {
        let snapshot = DoorStatusStore.load()
        guard !snapshot.isUnlocked, !Activity<DoorUnlockerActivityAttributes>.activities.isEmpty else { return }

        beginLiveActivityBackgroundTask()
        liveActivityCompletionTask = Task { await completeAndDismissLiveActivity(confirmationDuration: 0) }
    }

    func syncLiveActivity(state: String, startedAt: Date?, deadline: Date?) {
        if (state == "unlocked" || state == "unlocking"), let deadline, deadline > .now {
            isCompletingLiveActivity = false
            liveActivityCompletionTask?.cancel()
            beginLiveActivityBackgroundTask()
            Task { await startOrUpdateLiveActivity(state: state, startedAt: startedAt ?? .now, deadline: deadline) }
            scheduleLiveActivityCompletion(deadline: deadline)
        } else {
            guard !isCompletingLiveActivity else { return }
            liveActivityCompletionTask?.cancel()
            beginLiveActivityBackgroundTask()
            liveActivityCompletionTask = Task { await completeAndDismissLiveActivity() }
        }
    }

    func scheduleLiveActivityCompletion(deadline: Date) {
        liveActivityCompletionTask?.cancel()
        liveActivityCompletionTask = Task { [weak self] in
            let transitionStart = deadline.addingTimeInterval(-Self.liveActivityLockTransitionLeadSeconds)
            let sleepSeconds = max(0, transitionStart.timeIntervalSinceNow)
            if sleepSeconds > 0 {
                try? await Task.sleep(nanoseconds: UInt64(sleepSeconds * 1_000_000_000))
            }

            guard !Task.isCancelled else { return }
            await self?.completeAndDismissLiveActivity(deadline: deadline)
        }
    }
}
