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
    func setRequiresUnlockAuthentication(_ isRequired: Bool) {
        guard isRequired != requiresUnlockAuthentication else { return }
        guard areSettingsUnlocked else {
            lastError = "Open Settings with Face ID or passcode first"
            return
        }

        requiresUnlockAuthentication = isRequired
        UserDefaults.standard.set(isRequired, forKey: Self.unlockAuthenticationKey)
    }

    func setRequiresHoldToUnlock(_ isRequired: Bool) {
        guard isRequired != requiresHoldToUnlock else { return }
        guard areSettingsUnlocked else {
            lastError = "Open Settings with Face ID or passcode first"
            return
        }

        requiresHoldToUnlock = isRequired
        UserDefaults.standard.set(isRequired, forKey: Self.unlockHoldRequirementKey)
    }

    func updateUnlockHoldDurationSeconds(_ seconds: Double) {
        let clampedSeconds = DoorControllerPolicy.clampedUnlockHoldDurationSeconds(seconds)
        guard clampedSeconds != unlockHoldDurationSeconds else { return }
        guard areSettingsUnlocked else {
            lastError = "Open Settings with Face ID or passcode first"
            return
        }

        unlockHoldDurationSeconds = clampedSeconds
        UserDefaults.standard.set(clampedSeconds, forKey: Self.unlockHoldDurationKey)
    }

    func setUnlockNotificationsEnabled(_ isEnabled: Bool) {
        guard isEnabled != unlockNotificationsEnabled else { return }
        guard areSettingsUnlocked else {
            lastError = "Open Settings with Face ID or passcode first"
            return
        }

        if isEnabled {
            requestUnlockNotificationAuthorization()
        } else {
            unlockNotificationsEnabled = false
            unlockNotificationStatus = "Off"
            UserDefaults.standard.set(false, forKey: Self.unlockNotificationsKey)
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [doorUnlockerUnlockNotificationIdentifier])
        }
    }

    func setProximityUnlockEnabled(_ isEnabled: Bool) {
        guard isEnabled != proximityUnlockEnabled else { return }
        guard areSettingsUnlocked else {
            lastError = "Open Settings with Face ID or passcode first"
            return
        }

        proximityUnlockEnabled = isEnabled
        UserDefaults.standard.set(isEnabled, forKey: Self.proximityUnlockKey)
        locationManager.allowsBackgroundLocationUpdates = isEnabled
        if isEnabled {
            requestLocationAuthorizationIfNeeded()
            requestBackgroundReliabilityNotificationAuthorizationIfNeeded()
            if peripheral?.state == .connected {
                startRSSIMonitoringIfNeeded()
            }
        } else {
            stopRSSIMonitoring()
        }

        if isReady || !isEnabled {
            clearProximityUnlockArming()
        } else {
            clearProximityUnlockCandidate()
        }

        restartLockZoneMonitoring()
        if isEnabled {
            armProximityUnlockIfOutsideAndDisconnected()
        } else {
            cancelBackgroundReliabilityWarning()
            updateProximityUnlockStatus()
        }
    }

    func setProximityUnlockRSSIGateEnabled(_ isEnabled: Bool) {
        guard isEnabled != proximityUnlockRSSIGateEnabled else { return }
        guard areSettingsUnlocked else {
            lastError = "Open Settings with Face ID or passcode first"
            return
        }

        if isEnabled {
            let threshold = proximityUnlockRSSIThreshold ?? Self.defaultProximityUnlockRSSIThreshold
            proximityUnlockRSSIThreshold = threshold
            UserDefaults.standard.set(threshold, forKey: Self.proximityUnlockRSSIThresholdKey)
            peripheral?.readRSSI()
        } else {
            proximityUnlockRSSIThreshold = nil
            UserDefaults.standard.removeObject(forKey: Self.proximityUnlockRSSIThresholdKey)
        }

        updateProximityUnlockStatus()
        if proximityUnlockArmedAt != nil {
            _ = runProximityUnlockIfReady()
        }
    }

    func updateProximityUnlockRSSIThreshold(_ rssi: Int) {
        let threshold = DoorControllerPolicy.clampedProximityUnlockRSSIThreshold(rssi)
        guard threshold != proximityUnlockRSSIThreshold else { return }
        guard areSettingsUnlocked else {
            lastError = "Open Settings with Face ID or passcode first"
            return
        }

        proximityUnlockRSSIThreshold = threshold
        UserDefaults.standard.set(threshold, forKey: Self.proximityUnlockRSSIThresholdKey)
        peripheral?.readRSSI()
        updateProximityUnlockStatus()
        if proximityUnlockArmedAt != nil {
            _ = runProximityUnlockIfReady()
        }
    }

    func setDistanceUnit(_ unit: DistanceUnit) {
        guard unit != distanceUnit else { return }
        guard areSettingsUnlocked else {
            lastError = "Open Settings with Face ID or passcode first"
            return
        }

        distanceUnit = unit
        UserDefaults.standard.set(unit.rawValue, forKey: Self.distanceUnitKey)
    }

    func updateLockZoneRadiusMeters(_ meters: Double) {
        let clampedMeters = DoorControllerPolicy.clampedLockZoneRadiusMeters(meters)
        guard clampedMeters != lockZoneRadiusMeters else { return }
        guard areSettingsUnlocked else {
            lastError = "Open Settings with Face ID or passcode first"
            return
        }

        lockZoneRadiusMeters = clampedMeters
        UserDefaults.standard.set(clampedMeters, forKey: Self.lockZoneRadiusKey)
        updateLockZoneLocationSnapshotIfPossible()
        if lockZoneStatus != "Left zone" && lockZoneStatus != "Inside zone" {
            lockZoneStatus = "Radius \(formattedDistance(clampedMeters))"
        }
        restartLockZoneMonitoring()
    }

    func setLockZoneToCurrentLocation() {
        guard areSettingsUnlocked else {
            lastError = "Open Settings with Face ID or passcode first"
            return
        }

        requestCurrentLocation(for: .setLockZoneFromSettings)
    }

    func refreshLockZoneLocation() {
        requestLockZoneLocationSnapshotIfAvailable()
    }

    func startLockZoneLocationUpdates() {
        guard lockZoneCenter != nil else { return }

        isLockZoneLocationUpdating = true
        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            startBestAvailableLocationUpdates()
            if locationManager.authorizationStatus == .authorizedWhenInUse {
                requestAlwaysLocationAuthorizationIfNeeded()
            }
        case .denied, .restricted:
            lockZoneStatus = "Location off"
        @unknown default:
            lockZoneStatus = "Location unavailable"
        }
    }

    func stopLockZoneLocationUpdates() {
        isLockZoneLocationUpdating = false
        locationManager.stopUpdatingLocation()
    }

    func startLockZoneDirectionUpdates() {
        guard CLLocationManager.headingAvailable() else {
            lockZoneHeadingDegrees = nil
            return
        }

        locationManager.headingFilter = 3
        locationManager.startUpdatingHeading()
    }

    func stopLockZoneDirectionUpdates() {
        locationManager.stopUpdatingHeading()
        lockZoneHeadingDegrees = nil
        lockZoneHeadingAccuracyDegrees = nil
    }
}
