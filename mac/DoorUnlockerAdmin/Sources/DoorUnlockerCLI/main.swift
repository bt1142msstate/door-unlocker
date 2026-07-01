import DoorUnlockerCore
import AppKit
import Foundation

enum DoorUnlockerCLI {
    struct Options {
        var portPath: String?
        var command: [String]
    }

    static func main() {
        do {
            let options = try parseOptions(Array(CommandLine.arguments.dropFirst()))
            if options.portPath == nil, sendToRunningAppIfAvailable(options.command) {
                return
            }

            let port = try selectedPort(path: options.portPath)
            let connection = try SerialPortConnection(path: port.path)
            defer { connection.close() }

            Thread.sleep(forTimeInterval: 1.2)
            try run(options.command, connection: connection)
        } catch {
            fputs("door-unlocker: \(error.localizedDescription)\n", stderr)
            Foundation.exit(1)
        }
    }

    private static func parseOptions(_ arguments: [String]) throws -> Options {
        var portPath: String?
        var command: [String] = []
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--help" || argument == "-h" {
                printUsage()
                Foundation.exit(0)
            } else if argument == "--port" {
                index += 1
                guard index < arguments.count else { throw CLIError.missingPortPath }
                portPath = arguments[index]
            } else {
                command = Array(arguments[index...])
                break
            }
            index += 1
        }

        guard !command.isEmpty else { throw CLIError.missingCommand }
        return Options(portPath: portPath, command: command)
    }

    private static func sendToRunningAppIfAvailable(_ command: [String]) -> Bool {
        guard commandCanRunInApp(command),
              !NSRunningApplication.runningApplications(withBundleIdentifier: DoorLocalCommandBridge.appBundleIdentifier).isEmpty else {
            return false
        }

        var userInfo = [DoorLocalCommandBridge.commandKey: command[0]]
        if command[0] == "timeout", command.count >= 2 {
            userInfo[DoorLocalCommandBridge.argumentKey] = command[1]
        }

        DistributedNotificationCenter.default().postNotificationName(
            DoorLocalCommandBridge.notificationName,
            object: DoorLocalCommandBridge.sender,
            userInfo: userInfo,
            deliverImmediately: true
        )
        print("sent_to_app=\(command[0])")
        return true
    }

    private static func commandCanRunInApp(_ command: [String]) -> Bool {
        switch command.first {
        case "lock", "unlock", "toggle":
            return true
        case "timeout":
            return command.count >= 2 && Int(command[1]) != nil
        default:
            return false
        }
    }

    private static func selectedPort(path: String?) throws -> SerialPortCandidate {
        if let path {
            return SerialPortCandidate(path: path)
        }

        guard let port = SerialPortDiscovery.discover().first else {
            throw CLIError.noControllerPort
        }
        return port
    }

    private static func run(_ command: [String], connection: SerialPortConnection) throws {
        switch command[0] {
        case "status":
            let lines = try transact("app status", until: ["APP_STATUS_END"], connection: connection)
            printStatus(DoorSerialParser.parseStatus(from: lines))
        case "pairs", "devices":
            let lines = try transact("app pairs", until: ["APP_PAIRS_END"], connection: connection)
            printPairs(DoorSerialParser.parsePairs(from: lines))
        case "lock":
            try runStatusCommand("app lock", connection: connection)
        case "unlock":
            try runStatusCommand("app unlock", connection: connection)
        case "toggle":
            let statusLines = try transact("app status", until: ["APP_STATUS_END"], connection: connection)
            let status = DoorSerialParser.parseStatus(from: statusLines)
            try runStatusCommand(status.isUnlocked ? "app lock" : "app unlock", connection: connection)
        case "timeout":
            guard command.count >= 2, Int(command[1]) != nil else { throw CLIError.missingTimeout }
            try runStatusCommand("app timeout \(command[1])", connection: connection)
        case "pair-on":
            try runStatusCommand("app pair on", connection: connection)
        case "pair-off":
            try runStatusCommand("app pair off", connection: connection)
        case "approve":
            guard command.count >= 2 else { throw CLIError.missingApprovalCode }
            try runStatusCommand("app approve \(command[1])", connection: connection)
        case "reject":
            try runStatusCommand("app reject", connection: connection)
        case "remove":
            guard command.count >= 2 else { throw CLIError.missingDeviceTarget }
            try runStatusCommand("app remove \(command[1])", connection: connection)
        case "rename":
            guard command.count >= 3 else { throw CLIError.missingRenameArguments }
            let name = DoorDeviceNameNormalizer.normalized(command.dropFirst(2).joined(separator: " "), fallback: "")
            guard !name.isEmpty else { throw CLIError.missingRenameArguments }
            try runStatusCommand("app rename \(command[1]) \(name)", connection: connection)
        case "clear":
            try runStatusCommand("app clear pairs", connection: connection)
        case "trust-mac":
            let deviceName = Host.current().localizedName ?? "Mac"
            let payloadHex = try DoorCommandAuthenticator.pairingPayloadHex(deviceName: deviceName)
            try runStatusCommand("app pair usb \(payloadHex)", connection: connection)
        default:
            throw CLIError.unknownCommand(command[0])
        }
    }

    private static func runStatusCommand(_ command: String, connection: SerialPortConnection) throws {
        let lines = try transact(command, until: ["APP_STATUS_END"], connection: connection)
        if let response = DoorSerialParser.responseSummary(from: lines) {
            print(response)
        }
        printStatus(DoorSerialParser.parseStatus(from: lines))
    }

    private static func transact(
        _ command: String,
        until markers: Set<String>,
        connection: SerialPortConnection
    ) throws -> [String] {
        let lines = try connection.transact(command, until: markers, timeout: 5)
        if let errorLine = lines.first(where: { $0.hasPrefix("APP_ERROR") }) {
            throw CLIError.controllerError(errorLine)
        }
        return lines
    }

    private static func printStatus(_ status: ControllerStatus) {
        print("model=\(status.modelTitle)")
        print("state=\(status.bleState)")
        print("unlocked=\(status.isUnlocked ? "yes" : "no")")
        print("pairing_mode=\(status.pairingMode)")
        print("paired_count=\(status.pairedCount)")
        print("max_pairs=\(status.maxPairs)")
        print("auto_lock_seconds=\(status.autoLockSeconds)")
        if let remaining = status.autoLockRemainingSeconds {
            print("auto_lock_remaining_seconds=\(remaining)")
        }
        if let pendingName = status.pendingName {
            print("pending_name=\(pendingName)")
        }
    }

    private static func printPairs(_ pairs: [PairedDevice]) {
        if pairs.isEmpty {
            print("No trusted devices")
            return
        }

        for pair in pairs {
            print("\(pair.slot)\t\(pair.displayName)\t\(pair.fingerprint)")
        }
    }

    private static func printUsage() {
        print(
            """
            usage: door-unlocker [--port /dev/cu.usbmodemXXXX] COMMAND

            Commands:
              status
              lock | unlock | toggle
              timeout SECONDS
              pairs
              pair-on | pair-off
              approve CODE | reject
              remove SLOT_OR_FINGERPRINT
              rename SLOT_OR_FINGERPRINT NAME
              clear
              trust-mac
            """
        )
    }
}

enum CLIError: LocalizedError {
    case missingCommand
    case missingPortPath
    case noControllerPort
    case unknownCommand(String)
    case controllerError(String)
    case missingTimeout
    case missingApprovalCode
    case missingDeviceTarget
    case missingRenameArguments

    var errorDescription: String? {
        switch self {
        case .missingCommand:
            return "Missing command. Run `door-unlocker --help`."
        case .missingPortPath:
            return "Missing path after --port."
        case .noControllerPort:
            return "No USB-C controller serial port was found."
        case .unknownCommand(let command):
            return "Unknown command `\(command)`. Run `door-unlocker --help`."
        case .controllerError(let line):
            return line
        case .missingTimeout:
            return "Usage: door-unlocker timeout SECONDS"
        case .missingApprovalCode:
            return "Usage: door-unlocker approve CODE"
        case .missingDeviceTarget:
            return "Usage: door-unlocker remove SLOT_OR_FINGERPRINT"
        case .missingRenameArguments:
            return "Usage: door-unlocker rename SLOT_OR_FINGERPRINT NAME"
        }
    }
}

DoorUnlockerCLI.main()
