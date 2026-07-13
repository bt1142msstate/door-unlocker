import Foundation
import CryptoKit

public enum DoorFirmwarePackageFingerprint {
    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func matches(_ journal: DoorFirmwareUpdateJournal, packageURL: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: packageURL.path),
              let size = try? packageURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size == journal.packageByteCount else {
            return false
        }
        guard let expectedHash = journal.packageSHA256 else { return true }
        return (try? sha256(of: packageURL)) == expectedHash
    }
}

public enum DoorFirmwareUpdatePhase: String, Codable, CaseIterable, Sendable {
    case preparing
    case requestingBootloader
    case scanningForBootloader
    case uploading
    case verifying
    case paused
}

public struct DoorFirmwareUpdateJournal: Codable, Equatable, Sendable {
    public let transactionIdentifier: UUID
    public var targetVersion: String?
    public var packagePath: String
    public var packageByteCount: Int
    public var packageSHA256: String?
    public var phase: DoorFirmwareUpdatePhase
    public let startedAt: Date
    public var updatedAt: Date
    public var attemptCount: Int
    public var lastProgress: Int?
    public var lastError: String?

    public init(
        transactionIdentifier: UUID = UUID(),
        targetVersion: String?,
        packagePath: String,
        packageByteCount: Int,
        packageSHA256: String? = nil,
        phase: DoorFirmwareUpdatePhase = .preparing,
        startedAt: Date = Date(),
        updatedAt: Date = Date(),
        attemptCount: Int = 0,
        lastProgress: Int? = nil,
        lastError: String? = nil
    ) {
        self.transactionIdentifier = transactionIdentifier
        self.targetVersion = targetVersion
        self.packagePath = packagePath
        self.packageByteCount = max(0, packageByteCount)
        self.packageSHA256 = packageSHA256
        self.phase = phase
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.attemptCount = max(0, attemptCount)
        self.lastProgress = lastProgress.map { min(100, max(0, $0)) }
        self.lastError = lastError
    }

    public mutating func transition(
        to phase: DoorFirmwareUpdatePhase,
        progress: Int? = nil,
        error: String? = nil,
        at date: Date = Date()
    ) {
        if self.phase != phase, phase == .uploading {
            attemptCount += 1
        }
        self.phase = phase
        if let progress {
            lastProgress = min(100, max(0, progress))
        }
        lastError = error
        updatedAt = date
    }
}

public struct DoorFirmwareUpdateJournalStore {
    private let defaults: UserDefaults
    private let key: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(defaults: UserDefaults = .standard, key: String) {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> DoorFirmwareUpdateJournal? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? decoder.decode(DoorFirmwareUpdateJournal.self, from: data)
    }

    public func save(_ journal: DoorFirmwareUpdateJournal) {
        guard let data = try? encoder.encode(journal) else { return }
        defaults.set(data, forKey: key)
    }

    public func clear() {
        defaults.removeObject(forKey: key)
    }
}

public enum DoorFirmwareRecoveryAction: Equatable, Sendable {
    case none
    case completed
    case activationFailed
    case waitForController
    case needsPackage
    case resumeBootloaderUpload
    case verifyNormalFirmware
    case restartFromNormalFirmware
}

public enum DoorFirmwareRecoveryPolicy {
    public static func action(
        journal: DoorFirmwareUpdateJournal?,
        installedVersion: String?,
        isNormalControllerReady: Bool,
        isBootloaderDetected: Bool,
        isPackageAvailable: Bool
    ) -> DoorFirmwareRecoveryAction {
        guard let journal else { return .none }

        if let targetVersion = journal.targetVersion,
           let installedVersion,
           DoorFirmwareUpdatePolicy.isVersion(installedVersion, atLeast: targetVersion) {
            return .completed
        }
        if journal.targetVersion == nil, journal.phase == .verifying, isNormalControllerReady {
            return .completed
        }

        // A completed upload that reconnects to a known older application is
        // an activation failure, not a transport interruption. Retrying the
        // same payload immediately can overwrite the staged recovery image
        // and trap clients in an endless upload loop.
        if journal.targetVersion != nil,
           journal.phase == .verifying,
           journal.lastProgress == 100,
           isNormalControllerReady,
           let installedVersion,
           installedVersion.lowercased() != "unknown" {
            return .activationFailed
        }

        guard isPackageAvailable else { return .needsPackage }
        if isBootloaderDetected { return .resumeBootloaderUpload }
        guard isNormalControllerReady else { return .waitForController }

        if installedVersion == nil || installedVersion?.lowercased() == "unknown" {
            return .verifyNormalFirmware
        }
        return .restartFromNormalFirmware
    }
}
