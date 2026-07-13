import Foundation
import NordicDFU
import OSLog

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
        if !didInjectTransportLoss,
           let threshold = tuning.transportLossAtProgress,
           progress >= threshold,
           progress < 100 {
            didInjectTransportLoss = true
            emitTelemetry("fault_transport_loss_injected", "percent=\(progress)")
            fail("Bluetooth transport disconnected during firmware update.")
            return
        }
        let status = totalParts > 1 ? "Uploading firmware part \(part) of \(totalParts)" : "Uploading firmware"
        let averageKBs = max(0, avgSpeedBytesPerSecond / 1024)
        let eta = estimatedSecondsRemaining(progress: progress, averageBytesPerSecond: avgSpeedBytesPerSecond)
        notify(
            status: "\(status) - \(Int(averageKBs.rounded())) KB/s",
            progress: progress,
            estimatedSecondsRemaining: eta
        )
        if progress >= 100 {
            schedulePostUploadRecoveryIfNeeded(after: .seconds(12), replacingExisting: true)
        }

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
            emitTelemetry(
                "progress",
                "percent=\(progress) currentBps=\(Int(currentSpeedBytesPerSecond)) avgBps=\(Int(avgSpeedBytesPerSecond))"
            )
        }
    }

    public func logWith(_ level: LogLevel, message: String) {
        log.debug("NordicDFU[\(level.name(), privacy: .public)] \(message, privacy: .public)")
#if DEBUG
        let elapsed = updateStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        print(String(format: "DoorFirmwareDFU %.3fs [%@] %@", elapsed, level.name(), message))
#endif
    }
}
