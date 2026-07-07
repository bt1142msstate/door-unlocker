import Darwin
import Foundation

public enum SerialPortDiscovery {
    public static func discover() -> [SerialPortCandidate] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: "/dev") else {
            return []
        }

        return names
            .filter { name in
                name.hasPrefix("cu.usbmodem")
                    || name.hasPrefix("cu.usbserial")
                    || name.hasPrefix("cu.SLAB")
                    || name.hasPrefix("cu.wchusbserial")
            }
            .map { SerialPortCandidate(path: "/dev/\($0)") }
            .sorted { lhs, rhs in
                if lhs.isLikelyXiao != rhs.isLikelyXiao {
                    return lhs.isLikelyXiao
                }
                return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
            }
    }
}

public enum SerialPortError: LocalizedError {
    case openFailed(String)
    case configurationFailed(String)
    case writeFailed
    case readFailed
    case timeout(String)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let path):
            return "Could not open \(path)."
        case .configurationFailed(let path):
            return "Could not configure \(path) for 115200 baud serial."
        case .writeFailed:
            return "Could not write to the controller."
        case .readFailed:
            return "Could not read from the controller."
        case .timeout(let command):
            return "Timed out waiting for controller response to \(command)."
        }
    }
}

public final class SerialPortConnection: @unchecked Sendable {
    public let path: String
    private var fileDescriptor: Int32 = -1

    public init(path: String) throws {
        self.path = path

        let descriptor = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard descriptor >= 0 else {
            throw SerialPortError.openFailed(path)
        }

        fileDescriptor = descriptor

        do {
            try configure()
            tcflush(fileDescriptor, TCIOFLUSH)
        } catch {
            close()
            throw error
        }
    }

    deinit {
        close()
    }

    public func close() {
        if fileDescriptor >= 0 {
            Darwin.close(fileDescriptor)
            fileDescriptor = -1
        }
    }

    public func transact(_ command: String, until endMarkers: Set<String>, timeout: TimeInterval = 3.0) throws -> [String] {
        try writeLine(command)

        let deadline = Date().addingTimeInterval(timeout)
        var buffer = [UInt8](repeating: 0, count: 512)
        var pending = Data()
        var lines: [String] = []

        while Date() < deadline {
            let count = Darwin.read(fileDescriptor, &buffer, buffer.count)
            if count > 0 {
                pending.append(buffer, count: count)

                while let newlineRange = pending.firstRange(of: Data([0x0A])) {
                    let lineData = pending[..<newlineRange.lowerBound]
                    pending.removeSubrange(..<newlineRange.upperBound)

                    guard let rawLine = String(data: lineData, encoding: .utf8) else { continue }
                    let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !line.isEmpty else { continue }

                    lines.append(line)
                    if endMarkers.contains(line) {
                        return lines
                    }
                }
            } else if count == 0 || errno == EAGAIN || errno == EWOULDBLOCK {
                usleep(2_000)
            } else {
                throw SerialPortError.readFailed
            }
        }

        throw SerialPortError.timeout(command)
    }

    private func configure() throws {
        var options = termios()
        guard tcgetattr(fileDescriptor, &options) == 0 else {
            throw SerialPortError.configurationFailed(path)
        }

        cfmakeraw(&options)
        cfsetspeed(&options, speed_t(B115200))
        options.c_cflag |= tcflag_t(CLOCAL | CREAD)
        options.c_cflag &= ~tcflag_t(CSTOPB | PARENB)
        options.c_cflag &= ~tcflag_t(CSIZE)
        options.c_cflag |= tcflag_t(CS8)

        guard tcsetattr(fileDescriptor, TCSANOW, &options) == 0 else {
            throw SerialPortError.configurationFailed(path)
        }
    }

    private func writeLine(_ command: String) throws {
        tcflush(fileDescriptor, TCIFLUSH)
        let bytes = Array((command + "\n").utf8)
        let written = bytes.withUnsafeBufferPointer { pointer in
            Darwin.write(fileDescriptor, pointer.baseAddress, bytes.count)
        }

        guard written == bytes.count else {
            throw SerialPortError.writeFailed
        }
    }
}
