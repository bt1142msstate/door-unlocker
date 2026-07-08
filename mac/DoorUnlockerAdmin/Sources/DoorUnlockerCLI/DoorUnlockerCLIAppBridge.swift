import AppKit
import DoorUnlockerCore
import Foundation

enum DoorUnlockerCLIAppBridge {
    static func sendToRunningAppIfAvailable(_ command: [String]) -> Bool {
        guard commandCanRunInApp(command),
              !NSRunningApplication.runningApplications(withBundleIdentifier: DoorLocalCommandBridge.appBundleIdentifier).isEmpty else {
            return false
        }

        var commandName = command[0]
        var expectedFirmwareVersion: String?
        var shouldWaitForFirmwareVerification = false
        var userInfo = [DoorLocalCommandBridge.commandKey: commandName]
        if command[0] == "timeout", command.count >= 2 {
            userInfo[DoorLocalCommandBridge.argumentKey] = command[1]
        } else if command[0] == "angles", command.count >= 3 {
            userInfo[DoorLocalCommandBridge.argumentKey] = "\(command[1]) \(command[2])"
        } else if command[0] == "firmware-proof", command.count >= 3 {
            commandName = "firmware"
            userInfo[DoorLocalCommandBridge.commandKey] = commandName
            let absolutePath = URL(
                fileURLWithPath: command[1],
                relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            ).standardizedFileURL.path
            expectedFirmwareVersion = command[2]
            shouldWaitForFirmwareVerification = true
            userInfo[DoorLocalCommandBridge.argumentKey] = absolutePath
            userInfo[DoorLocalCommandBridge.expectedFirmwareVersionKey] = command[2]
        } else if (command[0] == "firmware" || command[0] == "firmware-recover"), command.count >= 2 {
            let rawPath = command.dropFirst().joined(separator: " ")
            let absolutePath = URL(
                fileURLWithPath: rawPath,
                relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            ).standardizedFileURL.path
            userInfo[DoorLocalCommandBridge.argumentKey] = absolutePath
        }

        DistributedNotificationCenter.default().postNotificationName(
            DoorLocalCommandBridge.notificationName,
            object: DoorLocalCommandBridge.sender,
            userInfo: userInfo,
            deliverImmediately: true
        )
        print("sent_to_app=\(commandName)")
        verifyFirmwareIfNeeded(shouldWait: shouldWaitForFirmwareVerification, expectedVersion: expectedFirmwareVersion)
        return true
    }

    private static func commandCanRunInApp(_ command: [String]) -> Bool {
        switch command.first {
        case "lock", "unlock", "toggle":
            return true
        case "timeout":
            return command.count >= 2 && Int(command[1]) != nil
        case "angles":
            return command.count >= 3 && Int(command[1]) != nil && Int(command[2]) != nil
        case "firmware", "firmware-recover":
            return command.count >= 2
        case "firmware-proof":
            return command.count >= 3
        default:
            return false
        }
    }

    private static func verifyFirmwareIfNeeded(shouldWait: Bool, expectedVersion: String?) {
        guard shouldWait, let expectedVersion else { return }
        let timeout = TimeInterval(Int(ProcessInfo.processInfo.environment["FIRMWARE_WAIT_SECONDS"] ?? "") ?? 420)
        if waitForFirmwareVerification(expectedVersion, timeout: timeout) {
            print("firmware_version=\(expectedVersion)")
            print("verified_over=ble")
        } else {
            fputs("Timed out waiting for firmware_version=\(expectedVersion) over BLE\n", stderr)
            Foundation.exit(1)
        }
    }

    private static func waitForFirmwareVerification(_ expectedVersion: String, timeout: TimeInterval) -> Bool {
        var verified = false
        let observer = DistributedNotificationCenter.default().addObserver(
            forName: DoorLocalCommandBridge.firmwareVerifiedNotificationName,
            object: DoorLocalCommandBridge.appBundleIdentifier,
            queue: .main
        ) { notification in
            guard let version = notification.userInfo?[DoorLocalCommandBridge.firmwareVersionKey] as? String else {
                return
            }
            if version == expectedVersion {
                verified = true
            }
        }
        defer {
            DistributedNotificationCenter.default().removeObserver(observer)
        }

        let deadline = Date().addingTimeInterval(timeout)
        while !verified && Date() < deadline {
            RunLoop.current.run(mode: .default, before: min(deadline, Date().addingTimeInterval(0.2)))
        }
        return verified
    }
}
