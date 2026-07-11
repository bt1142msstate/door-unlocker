import Foundation

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
