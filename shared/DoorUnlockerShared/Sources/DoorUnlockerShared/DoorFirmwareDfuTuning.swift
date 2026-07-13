import Foundation

public struct DoorFirmwareDfuTuning: Equatable, Sendable {
    public static let optimizedBootloaderName = "DoorDFU"
    public static let maxAdafruitPacketReceiptNotificationParameter: UInt16 = 32
    public static let defaultPacketReceiptNotificationParameter: UInt16 = 9
    public static let defaultMacPacketReceiptNotificationParameter: UInt16 =
        defaultPacketReceiptNotificationParameter
    public static let defaultDataObjectPreparationDelay: TimeInterval = 0.3
    public static let defaultScanTimeout: TimeInterval = 18
    public static let defaultConnectionTimeout: TimeInterval = 20

    public var packetReceiptNotificationParameter: UInt16
    public var dataObjectPreparationDelay: TimeInterval
    public var scanTimeout: TimeInterval
    public var connectionTimeout: TimeInterval
    public var transportLossAtProgress: Int?

    public init(
        packetReceiptNotificationParameter: UInt16 = Self.defaultPacketReceiptNotificationParameter,
        dataObjectPreparationDelay: TimeInterval = Self.defaultDataObjectPreparationDelay,
        scanTimeout: TimeInterval = Self.defaultScanTimeout,
        connectionTimeout: TimeInterval = Self.defaultConnectionTimeout,
        transportLossAtProgress: Int? = nil
    ) {
        self.packetReceiptNotificationParameter = Self.clampedPacketReceiptNotificationParameter(
            packetReceiptNotificationParameter
        )
        self.dataObjectPreparationDelay = Self.clampedDataObjectPreparationDelay(dataObjectPreparationDelay)
        self.scanTimeout = Self.clampedTimeout(scanTimeout, min: 5, max: 60)
        self.connectionTimeout = Self.clampedTimeout(connectionTimeout, min: 5, max: 60)
        self.transportLossAtProgress = transportLossAtProgress.flatMap { (1...99).contains($0) ? $0 : nil }
    }

    public static let stableDefault = DoorFirmwareDfuTuning()

    public func packetReceiptNotificationParameter(forBootloaderNamed name: String?) -> UInt16 {
        return packetReceiptNotificationParameter
    }

    public static func fromProcessInfo(
        _ processInfo: ProcessInfo = .processInfo,
        defaultPacketReceiptNotificationParameter: UInt16 = DoorFirmwareDfuTuning.defaultPacketReceiptNotificationParameter
    ) -> DoorFirmwareDfuTuning {
        from(
            arguments: processInfo.arguments,
            environment: processInfo.environment,
            defaultPacketReceiptNotificationParameter: defaultPacketReceiptNotificationParameter
        )
    }

    public static func from(
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaultPacketReceiptNotificationParameter: UInt16 = DoorFirmwareDfuTuning.defaultPacketReceiptNotificationParameter
    ) -> DoorFirmwareDfuTuning {
        DoorFirmwareDfuTuning(
            packetReceiptNotificationParameter: UInt16(
                optionalArgumentValue(named: "--debug-dfu-prn", arguments: arguments)
                    ?? environment["DOOR_UNLOCKER_DFU_PRN"]
                    ?? ""
            ) ?? defaultPacketReceiptNotificationParameter,
            dataObjectPreparationDelay: TimeInterval(
                optionalArgumentValue(named: "--debug-dfu-object-delay", arguments: arguments)
                    ?? environment["DOOR_UNLOCKER_DFU_OBJECT_DELAY"]
                    ?? ""
            ) ?? defaultDataObjectPreparationDelay,
            scanTimeout: TimeInterval(
                optionalArgumentValue(named: "--debug-dfu-scan-timeout", arguments: arguments)
                    ?? environment["DOOR_UNLOCKER_DFU_SCAN_TIMEOUT"]
                    ?? ""
            ) ?? defaultScanTimeout,
            connectionTimeout: TimeInterval(
                optionalArgumentValue(named: "--debug-dfu-connection-timeout", arguments: arguments)
                    ?? environment["DOOR_UNLOCKER_DFU_CONNECTION_TIMEOUT"]
                    ?? ""
            ) ?? defaultConnectionTimeout,
            transportLossAtProgress: Int(
                optionalArgumentValue(named: "--debug-dfu-transport-loss-progress", arguments: arguments)
                    ?? environment["DOOR_UNLOCKER_DFU_TRANSPORT_LOSS_PROGRESS"]
                    ?? ""
            )
        )
    }

    public static func benchmarkLaunchArguments(
        packetReceiptNotificationParameter: UInt16? = nil,
        dataObjectPreparationDelay: TimeInterval? = nil,
        scanTimeout: TimeInterval? = nil,
        connectionTimeout: TimeInterval? = nil
    ) -> [String] {
        var arguments: [String] = []
        if let packetReceiptNotificationParameter {
            arguments.append(contentsOf: ["--debug-dfu-prn", "\(packetReceiptNotificationParameter)"])
        }
        if let dataObjectPreparationDelay {
            arguments.append(contentsOf: ["--debug-dfu-object-delay", "\(dataObjectPreparationDelay)"])
        }
        if let scanTimeout {
            arguments.append(contentsOf: ["--debug-dfu-scan-timeout", "\(scanTimeout)"])
        }
        if let connectionTimeout {
            arguments.append(contentsOf: ["--debug-dfu-connection-timeout", "\(connectionTimeout)"])
        }
        return arguments
    }

    private static func optionalArgumentValue(named name: String, arguments: [String]) -> String? {
        for (index, argument) in arguments.enumerated() {
            if argument == name, index + 1 < arguments.count {
                return arguments[index + 1]
            }

            let prefix = "\(name)="
            if argument.hasPrefix(prefix) {
                return String(argument.dropFirst(prefix.count))
            }
        }
        return nil
    }

    private static func clampedPacketReceiptNotificationParameter(_ value: UInt16) -> UInt16 {
        min(value, maxAdafruitPacketReceiptNotificationParameter)
    }

    private static func clampedDataObjectPreparationDelay(_ value: TimeInterval) -> TimeInterval {
        clampedTimeout(value, min: 0.3, max: 0.4)
    }

    private static func clampedTimeout(_ value: TimeInterval, min minValue: TimeInterval, max maxValue: TimeInterval) -> TimeInterval {
        guard value.isFinite else { return maxValue }
        return Swift.max(minValue, Swift.min(maxValue, value))
    }
}
