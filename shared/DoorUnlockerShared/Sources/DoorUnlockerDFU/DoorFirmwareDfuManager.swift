import CoreBluetooth
import DoorUnlockerShared
import Foundation
import NordicDFU
import OSLog

public struct DoorFirmwareDfuUpdate: Equatable, Sendable {
    public let status: String
    public let progress: Int?
    public let estimatedSecondsRemaining: Int?

    public init(status: String, progress: Int?, estimatedSecondsRemaining: Int?) {
        self.status = status
        self.progress = progress
        self.estimatedSecondsRemaining = estimatedSecondsRemaining
    }
}

@MainActor
public protocol DoorFirmwareDfuManagerDelegate: AnyObject {
    func firmwareDfuManagerDidUpdate(_ update: DoorFirmwareDfuUpdate)
    func firmwareDfuManagerDidDetectControllerFirmware()
    func firmwareDfuManagerDidFinish()
    func firmwareDfuManagerDidFail(_ message: String)
}

public final class DoorFirmwareDfuManager: NSObject {
    private let secureDfuServiceUUID = CBUUID(string: "FE59")
    private let bootloaderDfuServiceUUID = CBUUID(string: "00001530-1212-EFDE-1523-785FEABCD123")
    private let controllerServiceUUID = CBUUID(string: "7A5A2000-2B8D-4C3E-94E7-0B3C0DDAAF10")
    private let dfuNameFragments = ["dfu", "adadfu", "dfutarg"]
    private let dfuQueue: DispatchQueue
    private let log: Logger
    private let tuning: DoorFirmwareDfuTuning
    private weak var delegate: DoorFirmwareDfuManagerDelegate?
    private var central: CBCentralManager?
    private var packageURL: URL?
    private var scanTimeoutTask: Task<Void, Never>?
    private var dfuInitiator: DFUServiceInitiator?
    private var dfuController: DFUServiceController?
    private var isActive = false
    private var updateStartedAt: Date?
    private var uploadStartedAt: Date?
    private var lastLoggedProgressBucket: Int?
    private var packageBytes = 0

    public init(
        delegate: DoorFirmwareDfuManagerDelegate,
        tuning: DoorFirmwareDfuTuning = .fromProcessInfo(),
        logSubsystem: String,
        queueLabel: String
    ) {
        self.delegate = delegate
        self.tuning = tuning
        self.log = Logger(subsystem: logSubsystem, category: "FirmwareUpdate")
        self.dfuQueue = DispatchQueue(label: queueLabel)
        super.init()
    }

    public func start(packageURL: URL) {
        cancel()
        isActive = true
        self.packageURL = packageURL
        updateStartedAt = Date()
        uploadStartedAt = nil
        lastLoggedProgressBucket = nil
        packageBytes = (try? packageURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let prn = tuning.packetReceiptNotificationParameter
        let objectDelay = tuning.dataObjectPreparationDelay
        let scanTimeout = tuning.scanTimeout
        log.info(
            """
            DFU scan started packageBytes=\(self.packageBytes, privacy: .public) \
            prn=\(prn, privacy: .public) objectDelay=\(objectDelay, privacy: .public) \
            scanTimeout=\(scanTimeout, privacy: .public)
            """
        )
        notify(status: "Looking for firmware update mode", progress: nil)
        central = CBCentralManager(delegate: self, queue: .main)
        scanTimeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(max(0, scanTimeout) * 1_000_000_000))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.fail("Controller did not advertise firmware update mode. Use USB-C recovery if it stays offline.")
        }
    }

    public func cancel() {
        isActive = false
        scanTimeoutTask?.cancel()
        scanTimeoutTask = nil
        central?.stopScan()
        central = nil
        _ = dfuController?.abort()
        dfuController = nil
        dfuInitiator = nil
        packageURL = nil
        updateStartedAt = nil
        uploadStartedAt = nil
        lastLoggedProgressBucket = nil
        packageBytes = 0
    }

    private func beginScanIfReady() {
        guard isActive,
              let central,
              central.state == .poweredOn else { return }
        notify(status: "Scanning for update bootloader", progress: nil)
        central.scanForPeripherals(withServices: nil, options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false
        ])
    }

    private func shouldUsePeripheral(name: String?, advertisementData: [String: Any]) -> Bool {
        let advertisedServices = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        if advertisedServices.contains(secureDfuServiceUUID) || advertisedServices.contains(bootloaderDfuServiceUUID) {
            return true
        }

        guard let normalizedName = name?.replacingOccurrences(of: " ", with: "").lowercased() else {
            return false
        }
        return dfuNameFragments.contains { normalizedName.contains($0) }
    }

    private func serviceList(from advertisementData: [String: Any]) -> String {
        let advertisedServices = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        if advertisedServices.isEmpty {
            return "none"
        }
        return advertisedServices.map(\.uuidString).joined(separator: ",")
    }

    private func startDfu(target peripheral: CBPeripheral) {
        guard isActive,
              let packageURL else {
            fail("Firmware package is missing.")
            return
        }

        central?.stopScan()
        central?.delegate = nil
        scanTimeoutTask?.cancel()
        scanTimeoutTask = nil
        uploadStartedAt = Date()
        log.info("DFU bootloader selected after \(self.elapsedText(since: self.updateStartedAt), privacy: .public)")
        notify(status: "Starting firmware upload", progress: 0)

        do {
            let firmware = try DFUFirmware(urlToZipFile: packageURL)
            let initiator = DFUServiceInitiator(queue: dfuQueue)
            initiator.delegate = self
            initiator.progressDelegate = self
            initiator.logger = self
            initiator.connectionTimeout = tuning.connectionTimeout
            initiator.dataObjectPreparationDelay = tuning.dataObjectPreparationDelay
            initiator.forceDfu = true
            initiator.packetReceiptNotificationParameter = tuning.packetReceiptNotificationParameter
            initiator.forceScanningForNewAddressInLegacyDfu = true
            dfuInitiator = initiator
            dfuController = initiator.with(firmware: firmware).start(target: peripheral)

            if dfuController == nil {
                fail("Firmware upload could not start.")
            }
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func notify(status: String, progress: Int?, estimatedSecondsRemaining: Int? = nil) {
        guard isActive else { return }
        let update = DoorFirmwareDfuUpdate(
            status: status,
            progress: progress,
            estimatedSecondsRemaining: estimatedSecondsRemaining
        )
        Task { @MainActor [weak self] in
            self?.delegate?.firmwareDfuManagerDidUpdate(update)
        }
    }

    private func finish() {
        guard isActive else { return }
        isActive = false
        scanTimeoutTask?.cancel()
        scanTimeoutTask = nil
        central?.stopScan()
        central = nil
        dfuController = nil
        dfuInitiator = nil
        packageURL = nil
        let totalElapsed = elapsedText(since: updateStartedAt)
        let uploadElapsed = elapsedText(since: uploadStartedAt)
        log.info("DFU completed total=\(totalElapsed, privacy: .public) upload=\(uploadElapsed, privacy: .public)")
        updateStartedAt = nil
        uploadStartedAt = nil
        lastLoggedProgressBucket = nil
        packageBytes = 0
        Task { @MainActor [weak self] in
            self?.delegate?.firmwareDfuManagerDidFinish()
        }
    }

    private func fail(_ message: String) {
        guard isActive else { return }
        isActive = false
        scanTimeoutTask?.cancel()
        scanTimeoutTask = nil
        central?.stopScan()
        central = nil
        _ = dfuController?.abort()
        dfuController = nil
        dfuInitiator = nil
        packageURL = nil
        log.error("DFU failed after \(self.elapsedText(since: self.updateStartedAt), privacy: .public): \(message, privacy: .public)")
        updateStartedAt = nil
        uploadStartedAt = nil
        lastLoggedProgressBucket = nil
        packageBytes = 0
        Task { @MainActor [weak self] in
            self?.delegate?.firmwareDfuManagerDidFail(message)
        }
    }

    private func elapsedText(since start: Date?) -> String {
        guard let start else { return "n/a" }
        return String(format: "%.1fs", Date().timeIntervalSince(start))
    }

    private func estimatedSecondsRemaining(progress: Int, averageBytesPerSecond: Double) -> Int? {
        DoorFirmwareProgressEstimation.secondsRemaining(
            progress: progress,
            packageBytes: packageBytes,
            averageBytesPerSecond: averageBytesPerSecond,
            elapsedUploadTime: uploadStartedAt.map { Date().timeIntervalSince($0) }
        )
    }
}

extension DoorFirmwareDfuManager: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard isActive else { return }
        if central.state == .poweredOn {
            beginScanIfReady()
        } else if central.state != .unknown && central.state != .resetting {
            fail("Bluetooth is not available for firmware update.")
        }
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard isActive else { return }
        let advertisedServices = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        if advertisedServices.contains(controllerServiceUUID) {
            log.info("Normal controller firmware detected during DFU recovery scan")
            cancel()
            Task { @MainActor [weak self] in
                self?.delegate?.firmwareDfuManagerDidDetectControllerFirmware()
            }
            return
        }
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
        guard shouldUsePeripheral(name: name, advertisementData: advertisementData) else { return }
        let bootloaderName = name ?? "unknown"
        let peripheralID = peripheral.identifier.uuidString
        let rssi = RSSI.intValue
        let advertisedServiceList = serviceList(from: advertisementData)
        log.info(
            """
            Selected DFU bootloader name=\(bootloaderName, privacy: .public) \
            id=\(peripheralID, privacy: .public) rssi=\(rssi, privacy: .public) \
            services=\(advertisedServiceList, privacy: .public)
            """
        )
        startDfu(target: peripheral)
    }
}

extension DoorFirmwareDfuManager: DFUServiceDelegate, DFUProgressDelegate, LoggerDelegate {
    public func dfuStateDidChange(to state: DFUState) {
        guard isActive else { return }
        switch state {
        case .completed:
            notify(status: "Firmware uploaded. Reconnecting...", progress: 100)
            finish()
        case .aborted:
            fail("Firmware update was aborted.")
        default:
            notify(status: state.description, progress: nil)
        }
    }

    public func dfuError(_ error: DFUError, didOccurWithMessage message: String) {
        guard isActive else { return }
        fail(message)
    }

    public func dfuProgressDidChange(
        for part: Int,
        outOf totalParts: Int,
        to progress: Int,
        currentSpeedBytesPerSecond: Double,
        avgSpeedBytesPerSecond: Double
    ) {
        guard isActive else { return }
        let status = totalParts > 1 ? "Uploading firmware part \(part) of \(totalParts)" : "Uploading firmware"
        let averageKBs = max(0, avgSpeedBytesPerSecond / 1024)
        let eta = estimatedSecondsRemaining(progress: progress, averageBytesPerSecond: avgSpeedBytesPerSecond)
        notify(
            status: "\(status) - \(Int(averageKBs.rounded())) KB/s",
            progress: progress,
            estimatedSecondsRemaining: eta
        )

        let bucket = min(100, (progress / 10) * 10)
        if bucket >= 10, bucket != lastLoggedProgressBucket {
            lastLoggedProgressBucket = bucket
            let uploadElapsed = elapsedText(since: uploadStartedAt)
            log.info(
                """
                DFU progress \(progress, privacy: .public)% \
                currentBps=\(currentSpeedBytesPerSecond, privacy: .public) \
                avgBps=\(avgSpeedBytesPerSecond, privacy: .public) \
                uploadElapsed=\(uploadElapsed, privacy: .public)
                """
            )
        }
    }

    public func logWith(_ level: LogLevel, message: String) {
        log.debug("NordicDFU[\(level.name(), privacy: .public)] \(message, privacy: .public)")
#if DEBUG
        print("DoorFirmwareDFU[\(level.name())] \(message)")
#endif
    }
}
