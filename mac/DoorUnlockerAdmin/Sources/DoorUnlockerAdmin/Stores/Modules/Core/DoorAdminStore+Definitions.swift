import CoreBluetooth
import DoorUnlockerCore
import DoorUnlockerDFU
import DoorUnlockerShared
import Foundation
import os

extension DoorAdminStore {
    typealias RuntimeTelemetryEntry = DoorAdminRuntimeTelemetryEntry

    typealias Command = DoorCommand
    typealias ControllerSettingOperation = DoorControllerSettingOperation

    enum WirelessCommandWriteIntent {
        case doorCommand
        case autoLockTimeout(Int)
        case lockName(String)
        case servoAngles(ServoAngles)
        case firmwareUpdate(URL)
        case linkAuthentication
        case pairingAdmin
        case generic

        var controllerSettingOperation: ControllerSettingOperation? {
            switch self {
            case .autoLockTimeout(let seconds):
                return .autoLockTimeout(seconds)
            case .lockName(let name):
                return .lockName(name)
            case .servoAngles(let angles):
                return .servoAngles(angles)
            default:
                return nil
            }
        }
    }

    enum WirelessCommandDispatchResult {
        case sent
        case queued
        case failed

        var isAccepted: Bool {
            self != .failed
        }
    }

    static let defaultLockName = "My Lock"
    static let minimumAutoLockSeconds = ControllerStatus.minimumAutoLockSeconds
    static let maximumAutoLockSeconds = ControllerStatus.maximumAutoLockSeconds
    static let lockNameKey = "DoorUnlockerAdminLockName"
    static let cachedBleStateKey = "DoorUnlockerAdminCachedBleState"
    static let cachedAutoLockSecondsKey = "DoorUnlockerAdminCachedAutoLockSeconds"
    static let cachedLockAngleKey = "DoorUnlockerAdminCachedLockAngle"
    static let cachedUnlockAngleKey = "DoorUnlockerAdminCachedUnlockAngle"
    static let cachedPairedCountKey = "DoorUnlockerAdminCachedPairedCount"
    static let cachedMaxPairsKey = "DoorUnlockerAdminCachedMaxPairs"
    static let cachedMaxConnectionsKey = "DoorUnlockerAdminCachedMaxConnections"
    static let cachedFirmwareVersionKey = "DoorUnlockerAdminCachedFirmwareVersion"
    static let trustedMacControllerKey = "DoorUnlockerAdminTrustedMacController"
    static let localSigningPublicKeyKey = "DoorUnlockerAdminLocalSigningPublicKey"
    static let knownPeripheralIdentifierKey = "DoorUnlockerAdminKnownPeripheralIdentifier"
    static let pairedDevicesSyncInterval: TimeInterval = 5
    static let wirelessStatePollInterval: TimeInterval = 10
    static let wirelessReconnectDelays: [TimeInterval] = [0.15, 0.45, 0.9, 1.8, 3.5]
    static let wirelessEncryptionRecoveryDelay: TimeInterval = 3
    static let knownPeripheralConnectionDeadline: TimeInterval = 5
    static let wirelessControlNonceRequestMinimumInterval: TimeInterval = 0.22
    static let wirelessControlNonceRequestTimeout: TimeInterval = 1.0
    static let usbStartupSyncGraceNanoseconds: UInt64 = 75_000_000
    static let localUSBDeviceHandle = "usb-c-this-mac"
    static let runtimeTraceWriter = DispatchQueue(label: "io.github.bt1142msstate.DoorUnlockerAdmin.runtimeTrace", qos: .utility)
    static let runtimeTraceFileURL: URL = {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return baseURL
            .appendingPathComponent("DoorUnlockerAdmin", isDirectory: true)
            .appendingPathComponent("startup-timing.log")
    }()
}
