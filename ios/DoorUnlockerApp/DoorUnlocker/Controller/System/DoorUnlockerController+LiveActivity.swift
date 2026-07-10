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
    func startOrUpdateLiveActivity(state: String, startedAt: Date, deadline: Date) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let contentState = DoorUnlockerActivityAttributes.ContentState(state: state, autoLockStartedAt: startedAt, autoLockDeadline: deadline)
        let content = ActivityContent(
            state: contentState,
            staleDate: deadline.addingTimeInterval(Self.liveActivityLockConfirmationSeconds + Self.liveActivityStaleGraceSeconds),
            relevanceScore: 1
        )

        do {
            if let activity = activeLiveActivity {
                liveActivity = activity
                await activity.update(content)
            } else {
                let attributes = DoorUnlockerActivityAttributes(title: lockName)
                liveActivity = try Activity<DoorUnlockerActivityAttributes>.request(
                    attributes: attributes,
                    content: content,
                    pushType: nil
                )
            }
        } catch {
            print("Live Activity unavailable: \(error.localizedDescription)")
        }
    }

    func completeAndDismissLiveActivity(deadline: Date? = nil, confirmationDuration: TimeInterval? = nil) async {
        guard !isCompletingLiveActivity else { return }

        isCompletingLiveActivity = true
        defer {
            isCompletingLiveActivity = false
            endLiveActivityBackgroundTask()
        }

        let activities = Activity<DoorUnlockerActivityAttributes>.activities
        guard liveActivity != nil || !activities.isEmpty else { return }
        let confirmationDuration = confirmationDuration ?? Self.liveActivityLockConfirmationSeconds
        let animationStartedAt = Date()
        let lockDeadline = deadline ?? animationStartedAt

        func liveActivityContent(
            state: String,
            phase: Int?,
            staleDate: Date?,
            relevanceScore: Double
        ) -> ActivityContent<DoorUnlockerActivityAttributes.ContentState> {
            ActivityContent(
                state: DoorUnlockerActivityAttributes.ContentState(
                    state: state,
                    autoLockStartedAt: animationStartedAt,
                    autoLockDeadline: lockDeadline,
                    lockAnimationStartedAt: animationStartedAt,
                    lockAnimationPhase: phase
                ),
                staleDate: staleDate,
                relevanceScore: relevanceScore
            )
        }

        let staleDate = max(lockDeadline, animationStartedAt)
            .addingTimeInterval(Self.liveActivityLockedVisibleSeconds + Self.liveActivityStaleGraceSeconds)

        func shouldContinueLockTransition() -> Bool {
            guard !Task.isCancelled else { return false }

            let snapshot = DoorStatusStore.load()
            if !snapshot.isUnlocked {
                return true
            }

            guard let deadline,
                  let snapshotDeadline = snapshot.autoLockDeadline else {
                return false
            }

            return abs(snapshotDeadline.timeIntervalSince(deadline)) < 1.5
        }

        func updatePhase(_ phase: Int, state: String = "locking", relevanceScore: Double = 0.7) async -> Bool {
            let content = liveActivityContent(state: state, phase: phase, staleDate: staleDate, relevanceScore: relevanceScore)
            for activity in Activity<DoorUnlockerActivityAttributes>.activities {
                await activity.update(content)
            }
            return shouldContinueLockTransition()
        }

        func pause(_ seconds: TimeInterval) async -> Bool {
            guard seconds > 0 else { return shouldContinueLockTransition() }
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return shouldContinueLockTransition()
        }

        if confirmationDuration > 0 {
            guard await updatePhase(0) else { return }
            guard await pause(Self.liveActivityLockAnimationSettleSeconds) else { return }
            guard await updatePhase(1) else { return }
            guard await pause(Self.liveActivityLockAnimationHalfSeconds) else { return }
            guard await updatePhase(2) else { return }
            let lockRevealDelay = deadline.map { max(Self.liveActivityLockAnimationSwapSeconds, $0.timeIntervalSinceNow) }
                ?? Self.liveActivityLockAnimationSwapSeconds
            guard await pause(lockRevealDelay) else { return }
            guard await updatePhase(3, state: "locked", relevanceScore: 0.8) else { return }
            guard await pause(Self.liveActivityLockAnimationHalfSeconds) else { return }
        }

        let finalContent = liveActivityContent(state: "locked", phase: 3, staleDate: nil, relevanceScore: 0.2)
        let lockedContent = liveActivityContent(state: "locked", phase: 3, staleDate: staleDate, relevanceScore: 0.4)
        for activity in Activity<DoorUnlockerActivityAttributes>.activities {
            await activity.update(lockedContent)
        }

        guard shouldContinueLockTransition() else { return }

        if confirmationDuration > 0 {
            let elapsed = Date().timeIntervalSince(animationStartedAt)
            let remainingConfirmation = max(0, confirmationDuration - elapsed)
            let lockedHoldSeconds = max(
                Self.liveActivityMinimumLockedHoldSeconds,
                Self.liveActivityLockedVisibleSeconds,
                remainingConfirmation
            )
            try? await Task.sleep(nanoseconds: UInt64(lockedHoldSeconds * 1_000_000_000))
            guard shouldContinueLockTransition() else { return }
        }

        for activity in Activity<DoorUnlockerActivityAttributes>.activities {
            await activity.end(finalContent, dismissalPolicy: .immediate)
        }
        liveActivity = nil
    }

    var activeLiveActivity: Activity<DoorUnlockerActivityAttributes>? {
        let activities = Activity<DoorUnlockerActivityAttributes>.activities
        return liveActivity.flatMap { activity in
            activity.activityState == .active || activity.activityState == .stale ? activity : nil
        } ?? activities.first { activity in
            activity.activityState == .active || activity.activityState == .stale
        }
    }

    func beginLiveActivityBackgroundTask() {
        guard liveActivityBackgroundTask == .invalid else { return }

        liveActivityBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "DoorUnlockerAutoLock") { [weak self] in
            Task { @MainActor in
                self?.endLiveActivityBackgroundTask()
            }
        }
    }

    func endLiveActivityBackgroundTask() {
        guard liveActivityBackgroundTask != .invalid else { return }

        UIApplication.shared.endBackgroundTask(liveActivityBackgroundTask)
        liveActivityBackgroundTask = .invalid
    }

    func beginWidgetReloadBackgroundTask() {
        guard widgetReloadBackgroundTask == .invalid else { return }

        widgetReloadBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "DoorUnlockerWidgetReload") { [weak self] in
            Task { @MainActor in
                self?.widgetReloadTask?.cancel()
                self?.endWidgetReloadBackgroundTask()
            }
        }
    }

    func endWidgetReloadBackgroundTask() {
        guard widgetReloadBackgroundTask != .invalid else { return }

        UIApplication.shared.endBackgroundTask(widgetReloadBackgroundTask)
        widgetReloadBackgroundTask = .invalid
    }

    func beginProximityUnlockBackgroundTask() {
        guard proximityUnlockEnabled,
              proximityUnlockBackgroundTask == .invalid else {
            return
        }

        proximityUnlockBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "DoorUnlockerProximityUnlock") { [weak self] in
            Task { @MainActor in
                self?.endProximityUnlockBackgroundTask()
            }
        }
    }

    func endProximityUnlockBackgroundTask() {
        guard proximityUnlockBackgroundTask != .invalid else { return }

        UIApplication.shared.endBackgroundTask(proximityUnlockBackgroundTask)
        proximityUnlockBackgroundTask = .invalid
    }

    func beginForceQuitReliabilityWarningBackgroundTask() {
        guard forceQuitReliabilityWarningBackgroundTask == .invalid else { return }

        forceQuitReliabilityWarningBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "DoorUnlockerForceQuitWarning") { [weak self] in
            Task { @MainActor in
                self?.forceQuitReliabilityWarningTask?.cancel()
                self?.cancelBackgroundReliabilityWarning()
                self?.endForceQuitReliabilityWarningBackgroundTask()
            }
        }
    }

    func endForceQuitReliabilityWarningBackgroundTask() {
        guard forceQuitReliabilityWarningBackgroundTask != .invalid else { return }

        UIApplication.shared.endBackgroundTask(forceQuitReliabilityWarningBackgroundTask)
        forceQuitReliabilityWarningBackgroundTask = .invalid
    }

}
