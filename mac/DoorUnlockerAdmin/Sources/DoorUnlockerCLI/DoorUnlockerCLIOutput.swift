import DoorUnlockerCore
import Foundation

enum DoorUnlockerCLIOutput {
    static func printStatus(_ status: ControllerStatus) {
        let localUSBDeviceHandle = "usb-c-this-mac"
        let localUSBDeviceName = DoorDeviceNameNormalizer.normalized(Host.current().localizedName ?? "Mac", fallback: "Mac") + " (USB-C)"
        let localUSBDevice = ConnectedControllerDevice(
            slot: 0,
            handle: localUSBDeviceHandle,
            name: localUSBDeviceName,
            isTrustedName: true
        )
        let unifiedStatus = status.includingLocalConnection(localUSBDevice)

        print("model=\(status.modelTitle)")
        print("firmware_version=\(status.firmwareVersion)")
        print("lock_name=\(status.lockName)")
        print("state=\(status.bleState)")
        print("unlocked=\(status.isUnlocked ? "yes" : "no")")
        print("pairing_mode=\(status.pairingMode)")
        print("paired_count=\(status.pairedCount)")
        print("max_pairs=\(status.maxPairs)")
        print("connected_count=\(unifiedStatus.connectedCount)")
        print("max_connections=\(unifiedStatus.maxConnections)")
        printConnectedDevices(unifiedStatus.connectedDevices, localUSBDeviceHandle: localUSBDeviceHandle)
        print("ble_connected_count=\(status.connectedCount)")
        print("ble_max_connections=\(status.maxConnections)")
        printBLEConnectedDevices(status.connectedDevices)
        print("auto_lock_seconds=\(status.autoLockSeconds)")
        print("lock_angle=\(status.lockAngle)")
        print("unlock_angle=\(status.unlockAngle)")
        print("servo_angle_range=\(status.servoMinAngle)-\(status.servoMaxAngle)")
        print("servo_min_angle_gap=\(status.servoMinAngleGap)")
        print("last_unlock=\(status.lastUnlockTitle)")
        printOptional("last_unlock_device_id", status.lastUnlockDeviceIdentifier)
        printOptional("last_unlock_device", status.lastUnlockDeviceName)
        if let remaining = status.autoLockRemainingSeconds {
            print("auto_lock_remaining_seconds=\(remaining)")
        }
        printOptional("pending_name", status.pendingName)
    }

    static func printPairs(_ pairs: [PairedDevice]) {
        if pairs.isEmpty {
            print("No trusted devices")
            return
        }

        for pair in pairs {
            print("\(pair.slot)\t\(pair.displayName)\t\(pair.fingerprint)")
        }
    }

    private static func printConnectedDevices(_ devices: [ConnectedControllerDevice], localUSBDeviceHandle: String) {
        for device in devices {
            let transport = device.handle == localUSBDeviceHandle ? "usb-c" : "bluetooth"
            print("connected_device=\(device.slot)\t\(device.displayName)\ttransport=\(transport)\ttrusted=\(device.isTrustedName ? "yes" : "no")")
        }
    }

    private static func printBLEConnectedDevices(_ devices: [ConnectedControllerDevice]) {
        for device in devices {
            print("ble_connected_device=\(device.slot)\t\(device.displayName)\ttrusted=\(device.isTrustedName ? "yes" : "no")")
        }
    }

    private static func printOptional(_ key: String, _ value: String?) {
        if let value {
            print("\(key)=\(value)")
        }
    }
}
