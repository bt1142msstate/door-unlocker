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
    func publishWidgetState(
        _ state: String,
        updatedAt: Date = .now,
        resetAutoLockDeadline: Bool = false,
        controllerRemainingSeconds: Int? = nil
    ) {
        let previousSnapshot = DoorStatusStore.load()
        let deadline = predictedAutoLockDeadline(
            for: state,
            updatedAt: updatedAt,
            resetAutoLockDeadline: resetAutoLockDeadline,
            controllerRemainingSeconds: controllerRemainingSeconds
        )
        let startedAt = predictedAutoLockStartedAt(
            for: state,
            updatedAt: updatedAt,
            resetAutoLockDeadline: resetAutoLockDeadline,
            controllerRemainingSeconds: controllerRemainingSeconds,
            deadline: deadline
        )
        DoorStatusStore.save(state: state, updatedAt: updatedAt, autoLockStartedAt: startedAt, autoLockDeadline: deadline)
        reloadDoorWidgets(deadline: deadline)
        notifyIfNeeded(for: state, previousSnapshot: previousSnapshot, deadline: deadline)
        scheduleAutoLockPrediction(deadline: deadline)
        syncLiveActivity(state: state, startedAt: startedAt, deadline: deadline)
    }

    func reloadDoorWidgets(deadline: Date? = nil) {
        requestDoorWidgetReload()
        widgetReloadTask?.cancel()
        widgetReloadGeneration += 1
        let generation = widgetReloadGeneration
        endWidgetReloadBackgroundTask()
        beginWidgetReloadBackgroundTask()

        let now = Date()
        var reloadDates = [1.0, 2.5, 6.0].map { now.addingTimeInterval($0) }
        if let deadline {
            reloadDates.append(deadline.addingTimeInterval(-0.25))
            reloadDates.append(deadline.addingTimeInterval(0.25))
            reloadDates.append(deadline.addingTimeInterval(1.5))
        }
        reloadDates = reloadDates
            .filter { $0 > now }
            .sorted()

        widgetReloadTask = Task { [weak self] in
            for reloadDate in reloadDates {
                let delay = reloadDate.timeIntervalSinceNow
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
                if Task.isCancelled { break }
                await MainActor.run {
                    self?.requestDoorWidgetReload()
                }
            }

            await MainActor.run {
                guard self?.widgetReloadGeneration == generation else { return }
                self?.endWidgetReloadBackgroundTask()
            }
        }
    }

    func requestDoorWidgetReload() {
        WidgetCenter.shared.reloadTimelines(ofKind: Self.widgetKind)
        WidgetCenter.shared.reloadAllTimelines()
    }
}
