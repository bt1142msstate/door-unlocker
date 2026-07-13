import CoreBluetooth
import DoorUnlockerShared
import Foundation
import NordicDFU
import OSLog

public final class DoorFirmwareDfuManager: NSObject {
    private let secureDfuServiceUUID = CBUUID(string: "FE59")
    private let bootloaderDfuServiceUUID = CBUUID(string: "00001530-1212-EFDE-1523-785FEABCD123")
    private let controllerServiceUUID = CBUUID(string: "7A5A2000-2B8D-4C3E-94E7-0B3C0DDAAF10")
    private let dfuNameFragments = ["dfu", "adadfu", "dfutarg"]
    private let dfuQueue: DispatchQueue
    let log: Logger
    private let tuning: DoorFirmwareDfuTuning
    private weak var delegate: DoorFirmwareDfuManagerDelegate?
    private var central: CBCentralManager?
    private var packageURL: URL?
    private var signedPackageURL: URL?
    private var scanTimeoutTask: Task<Void, Never>?
    private var completionRecoveryTask: Task<Void, Never>?
    private var dfuInitiator: DFUServiceInitiator?
    private var dfuController: DFUServiceController?
    var isActive = false
    var updateStartedAt: Date?
    var uploadStartedAt: Date?
    var lastLoggedProgressBucket: Int?
    var packageBytes = 0
    private var detectsNormalControllerFirmware = false
    private var allowsBootloaderUpload = true

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

    public func start(
        packageURL: URL,
        signedPackageURL: URL? = nil,
        detectsNormalControllerFirmware: Bool = false,
        allowsBootloaderUpload: Bool = true
    ) {
        cancel()
        isActive = true
        self.detectsNormalControllerFirmware = detectsNormalControllerFirmware
        self.allowsBootloaderUpload = allowsBootloaderUpload
        self.packageURL = packageURL
        self.signedPackageURL = signedPackageURL
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
        emitTelemetry("scan_started", "packageBytes=\(packageBytes) prn=\(prn) objectDelay=\(objectDelay)")
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
        completionRecoveryTask?.cancel()
        completionRecoveryTask = nil
        central?.stopScan()
        central = nil
        _ = dfuController?.abort()
        dfuController = nil
        dfuInitiator = nil
        packageURL = nil
        signedPackageURL = nil
        updateStartedAt = nil
        uploadStartedAt = nil
        lastLoggedProgressBucket = nil
        packageBytes = 0
        detectsNormalControllerFirmware = false
        allowsBootloaderUpload = true
    }
}

extension DoorFirmwareDfuManager {
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

    private func isNormalControllerFirmware(name: String?, advertisedServices: [CBUUID]) -> Bool {
        DoorFirmwareRecoveryIdentity.isNormalController(
            name: name,
            advertisesControllerService: advertisedServices.contains(controllerServiceUUID)
        )
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
              let packageURL = packageURL(forBootloaderNamed: peripheral.name) else {
            fail("Firmware package is missing.")
            return
        }

        central?.stopScan()
        central?.delegate = nil
        scanTimeoutTask?.cancel()
        scanTimeoutTask = nil
        uploadStartedAt = Date()
        let packageProfile = DoorFirmwarePackageProfile.select(forBootloaderNamed: peripheral.name)
        packageBytes = (try? packageURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        log.info(
            "DFU bootloader selected after \(self.elapsedText(since: self.updateStartedAt), privacy: .public) profile=\(packageProfile.rawValue, privacy: .public) packageBytes=\(self.packageBytes, privacy: .public)"
        )
        emitTelemetry("bootloader_selected", "profile=\(packageProfile.rawValue) packageBytes=\(packageBytes)")
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
            initiator.packetReceiptNotificationParameter = tuning
                .packetReceiptNotificationParameter(forBootloaderNamed: peripheral.name)
            initiator.forceScanningForNewAddressInLegacyDfu = true
            dfuInitiator = initiator
            dfuController = initiator.with(firmware: firmware).start(target: peripheral)

            if dfuController == nil {
                fail("Firmware upload could not start.")
            } else {
                // Nordic occasionally omits both its terminal progress and
                // completed callbacks after a successful reboot. Always bound
                // the upload phase with an independent normal-mode probe.
                schedulePostUploadRecoveryIfNeeded(after: .seconds(120))
            }
        } catch {
            fail(error.localizedDescription)
        }
    }

    func notify(status: String, progress: Int?, estimatedSecondsRemaining: Int? = nil) {
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

    func finish() {
        guard isActive else { return }
        isActive = false
        scanTimeoutTask?.cancel()
        scanTimeoutTask = nil
        completionRecoveryTask?.cancel()
        completionRecoveryTask = nil
        central?.stopScan()
        central = nil
        dfuController = nil
        dfuInitiator = nil
        packageURL = nil
        signedPackageURL = nil
        let totalElapsed = elapsedText(since: updateStartedAt)
        let uploadElapsed = elapsedText(since: uploadStartedAt)
        log.info("DFU completed total=\(totalElapsed, privacy: .public) upload=\(uploadElapsed, privacy: .public)")
        emitTelemetry("completed", "upload=\(uploadElapsed)")
        updateStartedAt = nil
        uploadStartedAt = nil
        lastLoggedProgressBucket = nil
        packageBytes = 0
        Task { @MainActor [weak self] in
            self?.delegate?.firmwareDfuManagerDidFinish()
        }
    }

    func fail(_ message: String) {
        guard isActive else { return }
        isActive = false
        scanTimeoutTask?.cancel()
        scanTimeoutTask = nil
        completionRecoveryTask?.cancel()
        completionRecoveryTask = nil
        central?.stopScan()
        central = nil
        _ = dfuController?.abort()
        dfuController = nil
        dfuInitiator = nil
        packageURL = nil
        signedPackageURL = nil
        log.error("DFU failed after \(self.elapsedText(since: self.updateStartedAt), privacy: .public): \(message, privacy: .public)")
        emitTelemetry("failed", "message=\(message)")
        updateStartedAt = nil
        uploadStartedAt = nil
        lastLoggedProgressBucket = nil
        packageBytes = 0
        Task { @MainActor [weak self] in
            self?.delegate?.firmwareDfuManagerDidFail(message)
        }
    }

    func elapsedText(since start: Date?) -> String {
        guard let start else { return "n/a" }
        return String(format: "%.1fs", Date().timeIntervalSince(start))
    }

    func emitTelemetry(_ event: String, _ details: String? = nil) {
#if DEBUG
        let elapsed = updateStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        let suffix = details.map { " \($0)" } ?? ""
        print(String(format: "DUFirmware %.3fs %@%@", elapsed, event, suffix))
#endif
    }

    func estimatedSecondsRemaining(progress: Int, averageBytesPerSecond: Double) -> Int? {
        DoorFirmwareProgressEstimation.secondsRemaining(
            progress: progress,
            packageBytes: packageBytes,
            averageBytesPerSecond: averageBytesPerSecond,
            elapsedUploadTime: uploadStartedAt.map { Date().timeIntervalSince($0) }
        )
    }

    private func packageURL(forBootloaderNamed name: String?) -> URL? {
        switch DoorFirmwarePackageProfile.select(forBootloaderNamed: name) {
        case .factoryCompatible:
            return packageURL
        case .signed:
            return signedPackageURL
        }
    }

    func schedulePostUploadRecoveryIfNeeded(
        after delay: Duration,
        replacingExisting: Bool = false
    ) {
        if completionRecoveryTask != nil {
            guard replacingExisting else { return }
            completionRecoveryTask?.cancel()
        }
        completionRecoveryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.beginPostUploadRecoveryScan()
        }
    }

    private func beginPostUploadRecoveryScan() {
        guard isActive else { return }
        completionRecoveryTask = nil
        log.warning("DFU completion callback missing after 100%; scanning for normal controller firmware")
        notify(status: "Firmware uploaded. Verifying controller...", progress: 100)
        dfuController = nil
        dfuInitiator = nil
        detectsNormalControllerFirmware = true
        allowsBootloaderUpload = false
        central?.stopScan()
        central?.delegate = nil
        central = CBCentralManager(delegate: self, queue: .main)
        scanTimeoutTask?.cancel()
        scanTimeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(45))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.fail("Firmware upload finished, but the controller did not return to normal mode.")
        }
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
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let role: DoorFirmwareRecoveryPeripheralRole
        if isNormalControllerFirmware(name: name, advertisedServices: advertisedServices) {
            role = .normalController
        } else if shouldUsePeripheral(name: name, advertisementData: advertisementData) {
            role = .bootloader
        } else {
            role = .unrelated
        }
        switch DoorFirmwareRecoveryScanPolicy.action(
            role: role,
            detectsNormalControllerFirmware: detectsNormalControllerFirmware,
            allowsBootloaderUpload: allowsBootloaderUpload
        ) {
        case .notifyNormalController:
            log.info("Normal controller firmware detected during DFU recovery scan")
            emitTelemetry("normal_firmware_detected")
            cancel()
            Task { @MainActor [weak self] in
                self?.delegate?.firmwareDfuManagerDidDetectControllerFirmware()
            }
            return
        case .ignore:
            return
        case .startBootloaderUpload:
            break
        }
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
