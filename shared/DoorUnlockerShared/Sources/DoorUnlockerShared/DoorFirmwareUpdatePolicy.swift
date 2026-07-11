import Foundation

public enum DoorFirmwareUpdateDecision: Equatable, Sendable {
    case missingBundledVersion
    case unknownInstalledVersion
    case upToDate
    case installedVersionIsNewer
    case installBundledVersion
}

public enum DoorFirmwareUpdatePolicy {
    public static func decision(installedVersion: String, bundledVersion: String?) -> DoorFirmwareUpdateDecision {
        guard let bundledVersion = normalizedVersion(bundledVersion) else {
            return .missingBundledVersion
        }

        guard let installedVersion = normalizedVersion(installedVersion),
              installedVersion.lowercased() != "unknown" else {
            return .unknownInstalledVersion
        }

        let comparison = compareVersions(bundledVersion, installedVersion)
        if comparison == .orderedDescending {
            return .installBundledVersion
        }

        if comparison == .orderedAscending {
            return .installedVersionIsNewer
        }

        return .upToDate
    }

    public static func shouldInstallBundledFirmware(installedVersion: String, bundledVersion: String?) -> Bool {
        decision(installedVersion: installedVersion, bundledVersion: bundledVersion) == .installBundledVersion
    }

    public static func isVersion(_ installedVersion: String, atLeast minimumVersion: String) -> Bool {
        guard let installedVersion = normalizedVersion(installedVersion),
              let minimumVersion = normalizedVersion(minimumVersion),
              installedVersion.lowercased() != "unknown" else {
            return false
        }
        return compareVersions(installedVersion, minimumVersion) != .orderedAscending
    }

    private static func normalizedVersion(_ version: String?) -> String? {
        guard let trimmed = version?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let lhsParts = numericParts(from: lhs)
        let rhsParts = numericParts(from: rhs)
        guard !lhsParts.isEmpty, !rhsParts.isEmpty else {
            return lhs.localizedStandardCompare(rhs)
        }

        let count = max(lhsParts.count, rhsParts.count)
        for index in 0..<count {
            let left = index < lhsParts.count ? lhsParts[index] : 0
            let right = index < rhsParts.count ? rhsParts[index] : 0
            if left > right { return .orderedDescending }
            if left < right { return .orderedAscending }
        }
        return .orderedSame
    }

    private static func numericParts(from version: String) -> [Int] {
        version
            .split { !$0.isNumber }
            .compactMap { Int($0) }
    }
}
