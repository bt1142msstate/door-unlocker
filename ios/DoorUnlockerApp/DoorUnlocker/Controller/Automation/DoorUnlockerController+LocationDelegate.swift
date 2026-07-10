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

extension DoorUnlockerController: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            switch manager.authorizationStatus {
            case .authorizedWhenInUse:
                requestTemporaryFullAccuracyIfNeeded()
                requestAlwaysLocationAuthorizationIfNeeded()
                if isLockZoneLocationUpdating {
                    startBestAvailableLocationUpdates()
                }
                if !pendingLocationRequests.isEmpty {
                    requestBestAvailableCurrentLocation()
                }
                restartLockZoneMonitoring()
            case .authorizedAlways:
                requestTemporaryFullAccuracyIfNeeded()
                if isLockZoneLocationUpdating {
                    startBestAvailableLocationUpdates()
                }
                if !pendingLocationRequests.isEmpty {
                    requestBestAvailableCurrentLocation()
                }
                restartLockZoneMonitoring()
            case .denied, .restricted:
                failPendingLocationRequests("Location off")
                lockZoneStatus = "Location off"
            case .notDetermined:
                break
            @unknown default:
                failPendingLocationRequests("Location unavailable")
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }

        Task { @MainActor in
            processPendingLocationRequests(with: location)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let heading = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        guard heading >= 0,
              newHeading.headingAccuracy >= 0 else { return }

        Task { @MainActor in
            lockZoneHeadingDegrees = heading
            lockZoneHeadingAccuracyDegrees = newHeading.headingAccuracy
        }
    }

    nonisolated func locationManagerShouldDisplayHeadingCalibration(_ manager: CLLocationManager) -> Bool {
        true
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            failPendingLocationRequests("Location unavailable")
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        guard region.identifier == doorUnlockerLockZoneRegionIdentifier else { return }

        Task { @MainActor in
            updateLockZoneContainment(from: .inside)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        guard region.identifier == doorUnlockerLockZoneRegionIdentifier else { return }

        Task { @MainActor in
            updateLockZoneContainment(from: .outside)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didDetermineState state: CLRegionState, for region: CLRegion) {
        guard region.identifier == doorUnlockerLockZoneRegionIdentifier else { return }

        Task { @MainActor in
            updateLockZoneContainment(from: state)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        guard region?.identifier == doorUnlockerLockZoneRegionIdentifier else { return }

        Task { @MainActor in
            lockZoneStatus = "Zone monitor off"
        }
    }
}
