import ActivityKit
import Foundation
import UIKit

@MainActor
final class DoorFirmwareLiveActivityCoordinator {
    private static let staleGraceSeconds: TimeInterval = 120
    private static let completionVisibleSeconds: TimeInterval = 3

    private var activity: Activity<DoorUnlockerActivityAttributes>?
    private var completionTask: Task<Void, Never>?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    func start(lockName: String, status: String, progress: Int?) {
        completionTask?.cancel()
        beginBackgroundTask()

        Task { [weak self] in
            await self?.startOrUpdate(lockName: lockName, status: status, progress: progress, state: "firmwareUpdating")
        }
    }

    func update(lockName: String, status: String, progress: Int?) {
        guard activity != nil || !Activity<DoorUnlockerActivityAttributes>.activities.isEmpty else {
            start(lockName: lockName, status: status, progress: progress)
            return
        }

        beginBackgroundTask()
        Task { [weak self] in
            await self?.startOrUpdate(lockName: lockName, status: status, progress: progress, state: "firmwareUpdating")
        }
    }

    func finish(lockName: String, version: String) {
        completionTask?.cancel()
        beginBackgroundTask()
        completionTask = Task { [weak self] in
            guard let self else { return }

            let status = "Controller is on \(version)"
            await startOrUpdate(
                lockName: lockName,
                status: status,
                progress: 100,
                state: "firmwareComplete",
                version: version,
                relevanceScore: 0.75
            )

            try? await Task.sleep(nanoseconds: UInt64(Self.completionVisibleSeconds * 1_000_000_000))
            await endCurrentActivity(lockName: lockName, status: status, progress: 100, state: "firmwareComplete", version: version)
            endBackgroundTask()
        }
    }

    func fail(lockName: String, message: String) {
        completionTask?.cancel()
        beginBackgroundTask()
        completionTask = Task { [weak self] in
            guard let self else { return }

            await startOrUpdate(
                lockName: lockName,
                status: message,
                progress: nil,
                state: "firmwareFailed",
                relevanceScore: 0.65
            )

            try? await Task.sleep(nanoseconds: UInt64(Self.completionVisibleSeconds * 1_000_000_000))
            await endCurrentActivity(lockName: lockName, status: message, progress: nil, state: "firmwareFailed")
            endBackgroundTask()
        }
    }

    private func startOrUpdate(
        lockName: String,
        status: String,
        progress: Int?,
        state: String,
        version: String? = nil,
        relevanceScore: Double = 1
    ) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            endBackgroundTask()
            return
        }

        let content = firmwareContent(
            status: status,
            progress: progress,
            state: state,
            version: version,
            relevanceScore: relevanceScore
        )

        do {
            if let activeActivity {
                activity = activeActivity
                await activeActivity.update(content)
            } else {
                activity = try Activity<DoorUnlockerActivityAttributes>.request(
                    attributes: DoorUnlockerActivityAttributes(title: lockName),
                    content: content,
                    pushType: nil
                )
            }
        } catch {
            print("Firmware Live Activity unavailable: \(error.localizedDescription)")
            endBackgroundTask()
        }
    }

    private func endCurrentActivity(
        lockName: String,
        status: String,
        progress: Int?,
        state: String,
        version: String? = nil
    ) async {
        let finalContent = firmwareContent(
            status: status,
            progress: progress,
            state: state,
            version: version,
            relevanceScore: 0.2,
            staleDate: nil
        )

        let activities = Activity<DoorUnlockerActivityAttributes>.activities.filter { activity in
            activity.id == self.activity?.id || activity.content.state.isFirmwareUpdate
        }
        for activity in activities {
            await activity.end(finalContent, dismissalPolicy: .immediate)
        }
        activity = nil
    }

    private func firmwareContent(
        status: String,
        progress: Int?,
        state: String,
        version: String? = nil,
        relevanceScore: Double,
        staleDate: Date? = Date().addingTimeInterval(staleGraceSeconds)
    ) -> ActivityContent<DoorUnlockerActivityAttributes.ContentState> {
        ActivityContent(
            state: DoorUnlockerActivityAttributes.ContentState(
                state: state,
                autoLockDeadline: Date().addingTimeInterval(Self.staleGraceSeconds),
                activityKind: "firmware",
                firmwareStatus: status,
                firmwareProgress: progress.map { max(0, min(100, $0)) },
                firmwareVersion: version
            ),
            staleDate: staleDate,
            relevanceScore: relevanceScore
        )
    }

    private var activeActivity: Activity<DoorUnlockerActivityAttributes>? {
        if let activity, activity.activityState == .active || activity.activityState == .stale {
            return activity
        }

        return Activity<DoorUnlockerActivityAttributes>.activities.first { activity in
            (activity.activityState == .active || activity.activityState == .stale)
                && activity.content.state.isFirmwareUpdate
        }
    }

    private func beginBackgroundTask() {
        guard backgroundTask == .invalid else { return }

        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "DoorUnlockerFirmwareUpdateActivity") { [weak self] in
            Task { @MainActor in
                self?.endBackgroundTask()
            }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }

        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}
