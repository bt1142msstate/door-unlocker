import CoreBluetooth
import Foundation
import NordicDFU
import OSLog

@MainActor
protocol DoorFirmwareDfuManagerDelegate: AnyObject {
    func firmwareDfuManagerDidUpdate(status: String, progress: Int?)
    func firmwareDfuManagerDidFinish()
    func firmwareDfuManagerDidFail(_ message: String)
}

final class DoorFirmwareDfuManager: NSObject {
    private let secureDfuServiceUUID = CBUUID(string: "FE59")
    private let legacyDfuServiceUUID = CBUUID(string: "00001530-1212-EFDE-1523-785FEABCD123")
    private let dfuNameFragments = ["dfu", "adadfu", "dfutarg"]
    private let dfuQueue = DispatchQueue(label: "io.github.bt1142msstate.DoorUnlocker.dfu")
    private let log = Logger(subsystem: "io.github.bt1142msstate.DoorUnlocker", category: "FirmwareUpdate")
    private weak var delegate: DoorFirmwareDfuManagerDelegate?
    private var central: CBCentralManager?
    private var packageURL: URL?
    private var scanTimeoutTask: Task<Void, Never>?
    private var dfuInitiator: DFUServiceInitiator?
    private var dfuController: DFUServiceController?
    private var isActive = false

    init(delegate: DoorFirmwareDfuManagerDelegate) {
        self.delegate = delegate
        super.init()
    }

    func start(packageURL: URL) {
        cancel()
        isActive = true
        self.packageURL = packageURL
        notify(status: "Looking for firmware update mode", progress: nil)
        central = CBCentralManager(delegate: self, queue: .main)
        scanTimeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(18))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.fail("Controller did not advertise firmware update mode. Use USB-C recovery if it stays offline.")
        }
    }

    func cancel() {
        isActive = false
        scanTimeoutTask?.cancel()
        scanTimeoutTask = nil
        central?.stopScan()
        central = nil
        _ = dfuController?.abort()
        dfuController = nil
        dfuInitiator = nil
        packageURL = nil
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
        if advertisedServices.contains(secureDfuServiceUUID) || advertisedServices.contains(legacyDfuServiceUUID) {
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
        notify(status: "Starting firmware upload", progress: 0)

        do {
            let firmware = try DFUFirmware(urlToZipFile: packageURL)
            let initiator = DFUServiceInitiator(queue: dfuQueue)
            initiator.delegate = self
            initiator.progressDelegate = self
            initiator.logger = self
            initiator.connectionTimeout = 20
            initiator.dataObjectPreparationDelay = 0.4
            initiator.forceDfu = true
            initiator.packetReceiptNotificationParameter = 8
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

    private func notify(status: String, progress: Int?) {
        guard isActive else { return }
        Task { @MainActor [weak self] in
            self?.delegate?.firmwareDfuManagerDidUpdate(status: status, progress: progress)
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
        Task { @MainActor [weak self] in
            self?.delegate?.firmwareDfuManagerDidFail(message)
        }
    }
}

extension DoorFirmwareDfuManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard isActive else { return }
        if central.state == .poweredOn {
            beginScanIfReady()
        } else if central.state != .unknown && central.state != .resetting {
            fail("Bluetooth is not available for firmware update.")
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard isActive else { return }
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
        guard shouldUsePeripheral(name: name, advertisementData: advertisementData) else { return }
        log.info("Selected DFU bootloader name=\(name ?? "unknown", privacy: .public) id=\(peripheral.identifier.uuidString, privacy: .public) rssi=\(RSSI.intValue, privacy: .public) services=\(self.serviceList(from: advertisementData), privacy: .public)")
        startDfu(target: peripheral)
    }
}

extension DoorFirmwareDfuManager: DFUServiceDelegate, DFUProgressDelegate, LoggerDelegate {
    func dfuStateDidChange(to state: DFUState) {
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

    func dfuError(_ error: DFUError, didOccurWithMessage message: String) {
        guard isActive else { return }
        fail(message)
    }

    func dfuProgressDidChange(
        for part: Int,
        outOf totalParts: Int,
        to progress: Int,
        currentSpeedBytesPerSecond: Double,
        avgSpeedBytesPerSecond: Double
    ) {
        guard isActive else { return }
        let status = totalParts > 1 ? "Uploading firmware part \(part) of \(totalParts)" : "Uploading firmware"
        notify(status: status, progress: progress)
    }

    func logWith(_ level: LogLevel, message: String) {
        log.debug("NordicDFU[\(level.name(), privacy: .public)] \(message, privacy: .public)")
#if DEBUG
        print("DoorFirmwareDFU[\(level.name())] \(message)")
#endif
    }
}
