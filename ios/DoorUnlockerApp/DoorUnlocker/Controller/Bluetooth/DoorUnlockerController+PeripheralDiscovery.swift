import CoreBluetooth
import CoreLocation
import DoorUnlockerDFU
import DoorUnlockerShared
import Foundation
import ActivityKit
import LocalAuthentication
import UIKit
import UserNotifications
import WidgetKit

extension DoorUnlockerController {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            guard isCurrentPeripheral(peripheral) else { return }

            if let error {
                lastError = error.localizedDescription
                scheduleReconnectCheck(after: Self.fastKnownControllerRetryDelay)
                return
            }

            let doorServices = peripheral.services?.filter { $0.uuid == serviceUUID } ?? []
            guard !doorServices.isEmpty else {
                if resumeBundledFirmwareFromDetectedBootloaderIfNeeded() {
                    return
                }
                lastError = "Door service not found"
                scheduleReconnectCheck(after: Self.fastKnownControllerRetryDelay)
                return
            }

#if DEBUG
            recordStartupTelemetry("services_discovered")
#endif
            discoverControllerServices(on: peripheral)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        Task { @MainActor in
            guard isCurrentPeripheral(peripheral) else { return }

            if let error {
                lastError = error.localizedDescription
                scheduleReconnectCheck(after: Self.fastKnownControllerRetryDelay)
                return
            }

            applyControllerCharacteristics(service.characteristics ?? [], on: peripheral)
#if DEBUG
            recordStartupTelemetry("characteristics_discovered")
#endif

            if !finishConnectionIfReady() {
                if hasPendingDoorCharacteristicDiscovery(on: peripheral) {
                    scheduleReconnectCheck(after: reconnectCheckDelay(6))
                    return
                }

                lastError = "Required controller characteristic not found"
                central?.cancelPeripheralConnection(peripheral)
                scheduleReconnectCheck(after: Self.fastKnownControllerRetryDelay)
            }
        }
    }
}
