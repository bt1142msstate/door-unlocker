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
    var isProximityUnlockRSSIGateSatisfied: Bool {
        guard let lockZoneBluetoothRSSI else { return false }
        return lockZoneBluetoothRSSI >= effectiveProximityUnlockRSSIThreshold
    }

    var effectiveProximityUnlockRSSIThreshold: Int {
        max(proximityUnlockRSSIThreshold ?? Self.reliableProximityUnlockRSSIThreshold, Self.reliableProximityUnlockRSSIThreshold)
    }

    func requestLocationAuthorizationIfNeeded() {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            requestTemporaryFullAccuracyIfNeeded()
            requestAlwaysLocationAuthorizationIfNeeded()
        case .authorizedAlways:
            requestTemporaryFullAccuracyIfNeeded()
        case .denied, .restricted:
            break
        @unknown default:
            break
        }
    }

    func requestAlwaysLocationAuthorizationIfNeeded() {
        guard proximityUnlockEnabled,
              !UserDefaults.standard.bool(forKey: Self.hasRequestedAlwaysLocationKey) else {
            return
        }

        UserDefaults.standard.set(true, forKey: Self.hasRequestedAlwaysLocationKey)
        locationManager.requestAlwaysAuthorization()
    }

    func requestTemporaryFullAccuracyIfNeeded() {
        guard locationManager.authorizationStatus == .authorizedWhenInUse || locationManager.authorizationStatus == .authorizedAlways,
              locationManager.accuracyAuthorization == .reducedAccuracy,
              !isRequestingTemporaryFullAccuracy else {
            return
        }

        isRequestingTemporaryFullAccuracy = true
        locationManager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: Self.lockZonePrecisionPurposeKey) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.isRequestingTemporaryFullAccuracy = false
                if self.locationManager.accuracyAuthorization == .reducedAccuracy {
                    self.lockZoneStatus = "Precise off"
                }
            }
        }
    }

    func configureBestAccuracyLocation() {
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.distanceFilter = kCLDistanceFilterNone
        locationManager.activityType = .otherNavigation
        locationManager.pausesLocationUpdatesAutomatically = false
    }

    func requestBestAvailableCurrentLocation() {
        configureBestAccuracyLocation()

        guard locationManager.accuracyAuthorization == .reducedAccuracy else {
            locationManager.requestLocation()
            return
        }

        guard !isRequestingTemporaryFullAccuracy else {
            locationManager.requestLocation()
            return
        }

        isRequestingTemporaryFullAccuracy = true
        locationManager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: Self.lockZonePrecisionPurposeKey) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.isRequestingTemporaryFullAccuracy = false
                if self.locationManager.accuracyAuthorization == .reducedAccuracy {
                    self.lockZoneStatus = "Precise off"
                }
                self.locationManager.requestLocation()
            }
        }
    }

    func startBestAvailableLocationUpdates() {
        configureBestAccuracyLocation()
        requestTemporaryFullAccuracyIfNeeded()
        if locationManager.accuracyAuthorization == .reducedAccuracy {
            lockZoneStatus = "Precise off"
        }
        locationManager.startUpdatingLocation()
    }

    func requestCurrentLocation(for request: LockZoneLocationRequest) {
        pendingLocationRequests.append(request)

        switch request {
        case .updateLockZoneAfterUnlock, .setLockZoneFromSettings:
            lockZoneStatus = "Finding location"
        case .proximityArmCheck:
            lockZoneStatus = "Checking zone"
        }

        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            requestBestAvailableCurrentLocation()
            if locationManager.authorizationStatus == .authorizedWhenInUse {
                requestAlwaysLocationAuthorizationIfNeeded()
            }
        case .denied, .restricted:
            failPendingLocationRequests("Location off")
        @unknown default:
            failPendingLocationRequests("Location unavailable")
        }
    }

    func failPendingLocationRequests(_ status: String) {
        let requests = pendingLocationRequests
        pendingLocationRequests.removeAll()
        guard !requests.isEmpty else { return }
        lockZoneStatus = status

        if requests.contains(where: { request in
            if case .proximityArmCheck = request { return true }
            return false
        }) {
            clearProximityUnlockCandidateIfUnarmed()
            proximityUnlockStatus = status
        }
    }

    func processPendingLocationRequests(with location: CLLocation) {
        let requests = pendingLocationRequests
        pendingLocationRequests.removeAll()
        updateLockZoneLocationSnapshot(location, mutatesContainment: requests.isEmpty)
        guard !requests.isEmpty else { return }

        for request in requests {
            process(location, for: request)
        }
    }

    func process(_ location: CLLocation, for request: LockZoneLocationRequest) {
        let accuracy = location.horizontalAccuracy
        guard accuracy >= 0, accuracy <= Self.maximumLockZoneAccuracyMeters else {
            switch request {
            case .proximityArmCheck:
                lockZoneStatus = "Accuracy low"
                clearProximityUnlockCandidateIfUnarmed()
                proximityUnlockStatus = "Zone unknown"
            case .updateLockZoneAfterUnlock, .setLockZoneFromSettings:
                lockZoneStatus = "Accuracy low"
                lastError = "Move near a window or try again to set the lock zone."
            }
            return
        }

        switch request {
        case .updateLockZoneAfterUnlock, .setLockZoneFromSettings:
            saveLockZone(center: location.coordinate)
        case .proximityArmCheck(let startedAt):
            resolveProximityArmCheck(startedAt: startedAt, location: location)
        }
    }
}
