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
    func recordStartupTelemetry(_ event: String, details: String? = nil, once: Bool = true) {
#if DEBUG
        if once, startupTelemetryEvents.contains(event) {
            return
        }
        if once {
            startupTelemetryEvents.insert(event)
        }

        let elapsedMilliseconds = Int(((ProcessInfo.processInfo.systemUptime - startupTelemetryStartedAt) * 1000).rounded())
        let entry = StartupTelemetryEntry(
            elapsedMilliseconds: elapsedMilliseconds,
            event: event,
            details: details?.isEmpty == false ? details : nil
        )
        startupTelemetryEntries.append(entry)
        if startupTelemetryEntries.count > 48 {
            startupTelemetryEntries.removeFirst(startupTelemetryEntries.count - 48)
        }

        if let details, !details.isEmpty {
            print("DUStartup \(elapsedMilliseconds)ms \(event) \(details)")
        } else {
            print("DUStartup \(elapsedMilliseconds)ms \(event)")
        }
#endif
    }

    func recordStartupStateChange(_ event: String, from oldValue: String, to newValue: String) {
        guard oldValue != newValue else { return }
        recordStartupTelemetry(event, details: "\(oldValue) -> \(newValue)", once: false)
    }

    func scheduleDeferredStartupHousekeeping() {
        startupHousekeepingTask?.cancel()
        startupHousekeepingTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            await MainActor.run {
                self?.runDeferredStartupHousekeeping()
            }
        }
    }

    func runDeferredStartupHousekeeping() {
        startupHousekeepingTask = nil
        refreshNotificationSettings()
        restartLockZoneMonitoring()
        dismissStoredLockedLiveActivityIfNeeded()
    }

    func resetSavedPeripheralIfIdentityChanged() {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: Self.knownPeripheralIdentityVersionKey) != Self.currentPeripheralIdentityVersion else {
            return
        }

        defaults.removeObject(forKey: Self.knownPeripheralIdentifierKey)
        defaults.set(Self.currentPeripheralIdentityVersion, forKey: Self.knownPeripheralIdentityVersionKey)
    }

    static func storedProximityUnlockEnabled() -> Bool {
        UserDefaults.standard.bool(forKey: proximityUnlockKey)
    }

    static func storedInitialServoState() -> String {
        switch DoorStatusStore.load().state {
        case "locked":
            return "locked"
        case "unlocked":
            return "unlocked"
        case "locking":
            return "locked"
        case "unlocking":
            return "unlocked"
        default:
            return "unknown"
        }
    }

    static func storedProximityUnlockRSSIThreshold() -> Int? {
        guard UserDefaults.standard.object(forKey: proximityUnlockRSSIThresholdKey) != nil else {
            return nil
        }

        return DoorControllerPolicy.clampedProximityUnlockRSSIThreshold(UserDefaults.standard.integer(forKey: proximityUnlockRSSIThresholdKey))
    }

    static func storedDistanceUnit() -> DistanceUnit {
        guard let rawValue = UserDefaults.standard.string(forKey: distanceUnitKey),
              let unit = DistanceUnit(rawValue: rawValue) else {
            return .meters
        }

        return unit
    }

    static func storedProximityUnlockArmedAt() -> Date? {
        let timestamp = UserDefaults.standard.double(forKey: proximityUnlockArmedAtKey)
        let storedArmedAt = timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : nil
        let restoredArmedAt = DoorControllerPolicy.restoredProximityUnlockArmedAt(
            enabled: storedProximityUnlockEnabled(),
            hasLockZone: storedLockZoneCenter() != nil,
            storedArmedAt: storedArmedAt,
            maximumAge: maximumStoredProximityUnlockArmAge
        )
        guard let restoredArmedAt else {
            UserDefaults.standard.removeObject(forKey: proximityUnlockArmedAtKey)
            return nil
        }

        return restoredArmedAt
    }

    static func storedAutoLockSeconds() -> Int {
        let storedValue = UserDefaults.standard.integer(forKey: autoLockSecondsKey)
        let seconds = storedValue == 0 ? defaultAutoLockSeconds : storedValue
        return DoorControllerPolicy.clampedAutoLockSeconds(seconds)
    }

    static func storedLastUnlockAt() -> Date? {
        let timestamp = UserDefaults.standard.double(forKey: lastUnlockAtKey)
        guard timestamp > 0 else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }

    static func storedLastUnlockDeviceIdentifier() -> String {
        guard let identifier = UserDefaults.standard.string(forKey: lastUnlockDeviceIdentifierKey) else {
            return ""
        }

        return sanitizedTrustedDeviceIdentifier(identifier)
    }

    static func storedLastUnlockDeviceName() -> String {
        guard let name = UserDefaults.standard.string(forKey: lastUnlockDeviceNameKey) else {
            return ""
        }

        return DoorControllerPolicy.sanitizedName(name, fallback: "Device")
    }

    static func sanitizedTrustedDeviceIdentifier(_ identifier: String) -> String {
        let normalized = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let ascii = normalized.unicodeScalars.compactMap { scalar -> String? in
            scalar.isASCII && scalar.value >= 33 && scalar.value <= 126 ? String(scalar) : nil
        }
        return String(ascii.joined().prefix(32))
    }

    static func storedLockZoneCenter() -> CLLocationCoordinate2D? {
        guard UserDefaults.standard.object(forKey: lockZoneLatitudeKey) != nil,
              UserDefaults.standard.object(forKey: lockZoneLongitudeKey) != nil else {
            return nil
        }

        let latitude = UserDefaults.standard.double(forKey: lockZoneLatitudeKey)
        let longitude = UserDefaults.standard.double(forKey: lockZoneLongitudeKey)
        guard CLLocationCoordinate2DIsValid(CLLocationCoordinate2D(latitude: latitude, longitude: longitude)) else {
            return nil
        }

        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    static func storedLockZoneRadiusMeters() -> Double {
        let storedValue = UserDefaults.standard.double(forKey: lockZoneRadiusKey)
        let radius = storedValue == 0 ? defaultLockZoneRadiusMeters : storedValue
        return DoorControllerPolicy.clampedLockZoneRadiusMeters(radius)
    }

    static func storedLockZoneUpdatedAt() -> Date? {
        let timestamp = UserDefaults.standard.double(forKey: lockZoneUpdatedAtKey)
        guard timestamp > 0 else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }

    static func storedUnlockHoldDurationSeconds() -> Double {
        let storedValue = UserDefaults.standard.double(forKey: unlockHoldDurationKey)
        let seconds = storedValue == 0 ? defaultUnlockHoldDurationSeconds : storedValue
        return DoorControllerPolicy.clampedUnlockHoldDurationSeconds(seconds)
    }

    static func storedDeviceDisplayName() -> String {
        if let storedName = UserDefaults.standard.string(forKey: deviceDisplayNameKey) {
            let sanitizedName = DoorControllerPolicy.sanitizedName(storedName, fallback: "iPhone")
            if !sanitizedName.isEmpty {
                return sanitizedName
            }
        }

        return DoorControllerPolicy.sanitizedName(UIDevice.current.name, fallback: "iPhone")
    }
}
