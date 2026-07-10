import CoreBluetooth
import DoorUnlockerCore
import DoorUnlockerDFU
import DoorUnlockerShared
import Foundation
import os

extension DoorAdminStore {
    func recordRuntimeTelemetry(_ event: String, details: String? = nil, once: Bool = true) {
        if once, runtimeTelemetryEvents.contains(event) {
            return
        }

        if once {
            runtimeTelemetryEvents.insert(event)
        }

        let elapsedMilliseconds = Int(((ProcessInfo.processInfo.systemUptime - runtimeTelemetryStartedAt) * 1000).rounded())
        let entry = RuntimeTelemetryEntry(
            elapsedMilliseconds: elapsedMilliseconds,
            event: event,
            details: details
        )
        runtimeTelemetryEntries.append(entry)
        if runtimeTelemetryEntries.count > 80 {
            runtimeTelemetryEntries.removeFirst(runtimeTelemetryEntries.count - 80)
        }

        if let details, !details.isEmpty {
            runtimeLog.notice("\(elapsedMilliseconds, privacy: .public)ms \(event, privacy: .public) \(details, privacy: .public)")
            print("DUMacStartup \(elapsedMilliseconds)ms \(event) \(details)")
            persistRuntimeTelemetryLine("DUMacStartup \(elapsedMilliseconds)ms \(event) \(details)")
        } else {
            runtimeLog.notice("\(elapsedMilliseconds, privacy: .public)ms \(event, privacy: .public)")
            print("DUMacStartup \(elapsedMilliseconds)ms \(event)")
            persistRuntimeTelemetryLine("DUMacStartup \(elapsedMilliseconds)ms \(event)")
        }
    }

    func recordRuntimeStateChange(_ event: String, from oldValue: String, to newValue: String) {
        guard oldValue != newValue else { return }
        recordRuntimeTelemetry(event, details: "\(oldValue) -> \(newValue)", once: false)
    }

    func persistRuntimeTelemetryLine(_ line: String) {
        let url = Self.runtimeTraceFileURL
        Self.runtimeTraceWriter.async {
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(atPath: url.path, contents: nil)
                }

                let handle = try FileHandle(forWritingTo: url)
                try handle.seekToEnd()
                if let data = "\(Date().ISO8601Format()) \(line)\n".data(using: .utf8) {
                    try handle.write(contentsOf: data)
                }
                try handle.close()
            } catch {
                // Telemetry must never affect controller control.
            }
        }
    }

    func scheduleStartupHousekeeping() {
        startupHousekeepingTask?.cancel()
        startupHousekeepingTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            let encodedPublicKey = await Task.detached(priority: .utility) {
                try? DoorCommandAuthenticator.publicKeyX963Representation().base64EncodedString()
            }.value
            await MainActor.run {
                self?.startupHousekeepingTask = nil
                self?.reconcileLocalSigningIdentityTrust(encodedPublicKey: encodedPublicKey)
            }
        }
    }

    func reconcileLocalSigningIdentityTrust(encodedPublicKey: String?) {
        guard let encodedPublicKey else { return }
        let storedPublicKey = UserDefaults.standard.string(forKey: Self.localSigningPublicKeyKey)
        UserDefaults.standard.set(encodedPublicKey, forKey: Self.localSigningPublicKeyKey)

        guard storedPublicKey != encodedPublicKey else { return }

        if hasTrustedMacController {
            setTrustedMacController(false)
            wirelessPairingState = "USB-C trust needed"
            message = "Connect USB-C once to trust this Mac"
        }
    }

}
