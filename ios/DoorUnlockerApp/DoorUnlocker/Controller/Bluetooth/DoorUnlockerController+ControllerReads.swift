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
    func parseControllerState(_ rawState: String) -> (state: String, remainingSeconds: Int?) {
        let trimmedState = rawState.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmedState.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              let remainingSeconds = Int(parts[1]) else {
            return (trimmedState, nil)
        }

        if parts[0] == "unlocked" {
            return ("unlocked", max(0, remainingSeconds))
        }

        if parts[0] == "timeout_set" {
            return ("timeout_set", max(0, remainingSeconds))
        }

        return (trimmedState, nil)
    }

}
