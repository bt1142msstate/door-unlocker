import Foundation

public enum DoorDistanceUnit: String, CaseIterable {
    case meters
    case feet
}

public enum DoorControllerPolicy {
    public static let defaultLockName = "My Lock"
    public static let defaultAutoLockSeconds = 30
    public static let minimumAutoLockSeconds = 5
    public static let maximumAutoLockSeconds = 120
    public static let defaultServoLockAngle = 20
    public static let defaultServoUnlockAngle = 95
    public static let minimumServoAngle = 10
    public static let maximumServoAngle = 170
    public static let minimumServoAngleGap = 10
    public static let defaultUnlockHoldDurationSeconds = 1.0
    public static let minimumUnlockHoldDurationSeconds = 0.5
    public static let maximumUnlockHoldDurationSeconds = 3.0
    public static let proximityUnlockArmDelaySeconds: TimeInterval = 8.0
    public static let proximityUnlockCooldownSeconds: TimeInterval = 30.0
    public static let defaultLockZoneRadiusMeters = 25.0
    public static let minimumLockZoneRadiusMeters = 5.0
    public static let maximumLockZoneRadiusMeters = 150.0
    public static let maximumLockZoneAccuracyMeters = 75.0
    public static let reliableProximityUnlockRSSIThreshold = -82
    public static let defaultProximityUnlockRSSIThreshold = reliableProximityUnlockRSSIThreshold
    public static let minimumProximityUnlockRSSIThreshold = reliableProximityUnlockRSSIThreshold
    public static let maximumProximityUnlockRSSIThreshold = -45

    public static var autoLockRange: ClosedRange<Int> {
        minimumAutoLockSeconds ... maximumAutoLockSeconds
    }

    public static var defaultServoAngles: DoorServoAngles {
        DoorServoAngles(lockAngle: defaultServoLockAngle, unlockAngle: defaultServoUnlockAngle)
    }

    public static var servoAngleRange: ClosedRange<Int> {
        minimumServoAngle ... maximumServoAngle
    }

    public static var unlockHoldDurationRange: ClosedRange<Double> {
        minimumUnlockHoldDurationSeconds ... maximumUnlockHoldDurationSeconds
    }

    public static var lockZoneRadiusRange: ClosedRange<Double> {
        minimumLockZoneRadiusMeters ... maximumLockZoneRadiusMeters
    }

    public static var proximityUnlockRSSIThresholdRange: ClosedRange<Int> {
        minimumProximityUnlockRSSIThreshold ... maximumProximityUnlockRSSIThreshold
    }

    public static func clampedAutoLockSeconds(_ seconds: Int) -> Int {
        min(max(seconds, minimumAutoLockSeconds), maximumAutoLockSeconds)
    }

    public static func clampedUnlockHoldDurationSeconds(_ seconds: Double) -> Double {
        let clampedSeconds = min(max(seconds, minimumUnlockHoldDurationSeconds), maximumUnlockHoldDurationSeconds)
        return (clampedSeconds * 4).rounded() / 4
    }

    public static func clampedLockZoneRadiusMeters(_ meters: Double) -> Double {
        min(max((meters / 5).rounded() * 5, minimumLockZoneRadiusMeters), maximumLockZoneRadiusMeters)
    }

    public static func clampedProximityUnlockRSSIThreshold(_ rssi: Int) -> Int {
        min(max(rssi, minimumProximityUnlockRSSIThreshold), maximumProximityUnlockRSSIThreshold)
    }

    public static func clampedServoAngles(
        _ angles: DoorServoAngles,
        range: ClosedRange<Int> = servoAngleRange
    ) -> DoorServoAngles {
        DoorServoAngles(
            lockAngle: min(max(angles.lockAngle, range.lowerBound), range.upperBound),
            unlockAngle: min(max(angles.unlockAngle, range.lowerBound), range.upperBound)
        )
    }

    public static func servoAnglesAreValid(
        _ angles: DoorServoAngles,
        range: ClosedRange<Int> = servoAngleRange,
        minimumGap: Int = minimumServoAngleGap
    ) -> Bool {
        range.contains(angles.lockAngle)
            && range.contains(angles.unlockAngle)
            && abs(angles.lockAngle - angles.unlockAngle) >= max(1, minimumGap)
    }

    public static func formattedDistance(_ meters: Double, unit: DoorDistanceUnit) -> String {
        switch unit {
        case .meters:
            guard meters >= 1000 else { return "\(Int(meters.rounded())) m" }
            return String(format: "%.1f km", meters / 1000)
        case .feet:
            return "\(Int((meters * 3.28084).rounded())) ft"
        }
    }

    public static func sanitizedName(_ name: String, fallback: String = defaultLockName) -> String {
        DoorNameNormalizer.normalized(name, fallback: fallback)
    }
}
