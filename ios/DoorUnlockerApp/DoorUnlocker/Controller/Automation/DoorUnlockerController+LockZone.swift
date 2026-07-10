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
    func saveLockZone(center: CLLocationCoordinate2D) {
        guard CLLocationCoordinate2DIsValid(center) else { return }

        let updatedAt = Date()
        lockZoneCenter = center
        lockZoneUpdatedAt = updatedAt
        lockZoneStatus = "Zone set"
        setKnownOutsideLockZone(false)

        UserDefaults.standard.set(center.latitude, forKey: Self.lockZoneLatitudeKey)
        UserDefaults.standard.set(center.longitude, forKey: Self.lockZoneLongitudeKey)
        UserDefaults.standard.set(lockZoneRadiusMeters, forKey: Self.lockZoneRadiusKey)
        UserDefaults.standard.set(updatedAt.timeIntervalSince1970, forKey: Self.lockZoneUpdatedAtKey)
        restartLockZoneMonitoring()
    }

    func resolveProximityArmCheck(startedAt: Date, location: CLLocation) {
        guard proximityUnlockCandidateStartedAt == startedAt else {
            updateProximityUnlockStatus()
            return
        }

        guard let lockZoneCenter else {
            armProximityUnlockIfCandidateStillCurrent(startedAt: startedAt)
            return
        }

        let lockLocation = CLLocation(latitude: lockZoneCenter.latitude, longitude: lockZoneCenter.longitude)
        let distance = location.distance(from: lockLocation)
        let insideBoundary = lockZoneRadiusMeters + max(location.horizontalAccuracy, 0)

        if distance <= insideBoundary {
            setKnownOutsideLockZone(false)
            clearProximityUnlockCandidateIfUnarmed()
            lockZoneStatus = "Inside zone"
            proximityUnlockStatus = "Inside zone"
        } else {
            setKnownOutsideLockZone(true)
            lockZoneStatus = "Left zone"
            armProximityUnlockIfCandidateStillCurrent(startedAt: startedAt)
        }
    }

    func requestLockZoneLocationSnapshotIfAvailable() {
        guard lockZoneCenter != nil else { return }

        switch locationManager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            requestBestAvailableCurrentLocation()
        default:
            break
        }
    }

    func updateLockZoneLocationSnapshotIfPossible() {
        guard let latestLockZoneLocation else { return }
        updateLockZoneLocationSnapshot(latestLockZoneLocation, mutatesContainment: true)
    }

    func updateLockZoneLocationSnapshot(_ location: CLLocation, mutatesContainment: Bool) {
        latestLockZoneLocation = location
        lockZoneUserLocation = location.coordinate
        lockZoneUserAccuracyMeters = location.horizontalAccuracy >= 0 ? location.horizontalAccuracy : nil
        lockZoneSpeedMetersPerSecond = location.speed >= 0 ? location.speed : nil
        lockZoneCourseDegrees = location.course >= 0 ? location.course : nil
        lockZoneCourseAccuracyDegrees = location.courseAccuracy >= 0 ? location.courseAccuracy : nil

        guard let lockZoneCenter else {
            lockZoneDistanceMeters = nil
            return
        }

        let lockLocation = CLLocation(latitude: lockZoneCenter.latitude, longitude: lockZoneCenter.longitude)
        let distance = location.distance(from: lockLocation)
        lockZoneDistanceMeters = distance

        guard mutatesContainment,
              proximityUnlockArmedAt == nil,
              proximityUnlockCandidateStartedAt == nil else {
            return
        }

        let accuracy = max(location.horizontalAccuracy, 0)
        guard accuracy <= Self.maximumLockZoneAccuracyMeters else {
            lockZoneStatus = "Accuracy low"
            updateProximityUnlockStatus()
            return
        }

        let isOutside = distance > lockZoneRadiusMeters + accuracy
        setKnownOutsideLockZone(isOutside)
        lockZoneStatus = isOutside ? "Left zone" : "Inside zone"
        if isOutside {
            armProximityUnlockIfOutsideAndDisconnected()
        } else {
            updateProximityUnlockStatus()
        }
    }

    func setKnownOutsideLockZone(_ isOutside: Bool) {
        isKnownOutsideLockZone = isOutside
        UserDefaults.standard.set(isOutside, forKey: Self.lockZoneOutsideKey)
    }

    func markProximityUnlockReturnDetected() {
        setKnownOutsideLockZone(false)
        lockZoneStatus = "Returned to zone"
    }

    func restartLockZoneMonitoring() {
        stopLockZoneMonitoring()

        guard proximityUnlockEnabled,
              let lockZoneCenter,
              CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else {
            stopProximityBackgroundLocationMonitoring()
            return
        }

        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
            stopProximityBackgroundLocationMonitoring()
            return
        case .authorizedWhenInUse:
            requestAlwaysLocationAuthorizationIfNeeded()
        case .authorizedAlways:
            break
        case .denied, .restricted:
            lockZoneStatus = "Location off"
            stopProximityBackgroundLocationMonitoring()
            return
        @unknown default:
            stopProximityBackgroundLocationMonitoring()
            return
        }

        let maximumRadius = locationManager.maximumRegionMonitoringDistance
        let radius = min(lockZoneRadiusMeters, maximumRadius > 0 ? maximumRadius : lockZoneRadiusMeters)
        let region = CLCircularRegion(center: lockZoneCenter, radius: radius, identifier: doorUnlockerLockZoneRegionIdentifier)
        region.notifyOnEntry = true
        region.notifyOnExit = true
        locationManager.startMonitoring(for: region)
        locationManager.requestState(for: region)
        requestLockZoneLocationSnapshotIfAvailable()
        startProximityBackgroundLocationMonitoringIfNeeded()
    }

    func stopLockZoneMonitoring() {
        for region in locationManager.monitoredRegions where region.identifier == doorUnlockerLockZoneRegionIdentifier {
            locationManager.stopMonitoring(for: region)
        }
    }

    func startProximityBackgroundLocationMonitoringIfNeeded() {
        guard proximityUnlockEnabled,
              lockZoneCenter != nil,
              locationManager.authorizationStatus == .authorizedAlways else {
            stopProximityBackgroundLocationMonitoring()
            return
        }

        guard !isSignificantLocationMonitoringActive else { return }
        locationManager.startMonitoringSignificantLocationChanges()
        isSignificantLocationMonitoringActive = true
    }

    func stopProximityBackgroundLocationMonitoring() {
        guard isSignificantLocationMonitoringActive else { return }
        locationManager.stopMonitoringSignificantLocationChanges()
        isSignificantLocationMonitoringActive = false
    }

    func updateLockZoneContainment(from state: CLRegionState) {
        switch state {
        case .inside:
            setKnownOutsideLockZone(false)
            lockZoneStatus = proximityUnlockArmedAt == nil ? "Inside zone" : "Returned to zone"
            clearProximityUnlockCandidateIfUnarmed()
        case .outside:
            setKnownOutsideLockZone(true)
            lockZoneStatus = "Left zone"
            armProximityUnlockIfOutsideAndDisconnected()
        case .unknown:
            lockZoneStatus = "Zone unknown"
        @unknown default:
            lockZoneStatus = "Zone unknown"
        }

        updateProximityUnlockStatus()
    }

    @discardableResult
    func runProximityUnlockIfReady() -> Bool {
        guard proximityUnlockEnabled, proximityUnlockArmedAt != nil else {
            updateProximityUnlockStatus()
            return false
        }

        // Location arms the one-shot action. A secure Bluetooth reconnect is the return trigger.
        beginProximityUnlockBackgroundTask()

        guard isSecureCommandWriteReady, pendingSystemCommand == nil else {
            updateProximityUnlockStatus()
            return false
        }

        guard !isUnlocked else {
            markProximityUnlockReturnDetected()
            clearProximityUnlockArming()
            updateProximityUnlockStatus()
            return false
        }

        let now = Date()
        if let lastProximityUnlockAt,
           now.timeIntervalSince(lastProximityUnlockAt) < Self.proximityUnlockCooldownSeconds {
            markProximityUnlockReturnDetected()
            clearProximityUnlockArming()
            updateProximityUnlockStatus()
            return false
        }

        guard isProximityUnlockRSSIGateSatisfied else {
            peripheral?.readRSSI()
            updateProximityUnlockStatus()
            return false
        }

        markProximityUnlockReturnDetected()
        proximityUnlockStatus = "Unlocking"
        if sendAuthenticated(.unlock, origin: .proximity) {
            clearProximityUnlockArming()
            lastProximityUnlockAt = now
            proximityUnlockStatus = "Unlocking"
            return true
        } else {
            restoreProximityUnlockAfterInterruptedCommand()
            return false
        }
    }
}
