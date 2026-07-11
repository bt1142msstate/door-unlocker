import Combine

public struct DoorControlPresentationContinuityObservation: Equatable, Sendable {
    public var isControlEstablished: Bool
    public var isTransientConnection: Bool

    public init(isControlEstablished: Bool, isTransientConnection: Bool) {
        self.isControlEstablished = isControlEstablished
        self.isTransientConnection = isTransientConnection
    }
}

public enum DoorControlContinuityEffect: Equatable, Sendable {
    case none
    case cancelExpiration
    case scheduleExpiration
}

public struct DoorControlPresentationContinuity: Equatable, Sendable {
    public static let retentionMilliseconds: Int64 = 900

    public private(set) var hasEstablishedControl = false
    public private(set) var isRetainingControl = false

    public init() {}

    public mutating func observe(
        isControlEstablished: Bool,
        isTransientConnection: Bool
    ) -> DoorControlContinuityEffect {
        if isControlEstablished {
            let shouldCancel = isRetainingControl
            hasEstablishedControl = true
            isRetainingControl = false
            return shouldCancel ? .cancelExpiration : .none
        }

        guard hasEstablishedControl, isTransientConnection else {
            let shouldCancel = isRetainingControl
            hasEstablishedControl = false
            isRetainingControl = false
            return shouldCancel ? .cancelExpiration : .none
        }

        guard !isRetainingControl else { return .none }
        isRetainingControl = true
        return .scheduleExpiration
    }

    public mutating func expire() {
        hasEstablishedControl = false
        isRetainingControl = false
    }
}

@MainActor
public final class DoorControlPresentationContinuityCoordinator: ObservableObject {
    @Published public private(set) var isRetainingControl = false

    private var continuity = DoorControlPresentationContinuity()
    private var expirationTask: Task<Void, Never>?

    public init() {}

    public func observe(_ observation: DoorControlPresentationContinuityObservation) {
        let effect = continuity.observe(
            isControlEstablished: observation.isControlEstablished,
            isTransientConnection: observation.isTransientConnection
        )
        isRetainingControl = continuity.isRetainingControl

        switch effect {
        case .none:
            break
        case .cancelExpiration:
            expirationTask?.cancel()
            expirationTask = nil
        case .scheduleExpiration:
            expirationTask?.cancel()
            expirationTask = Task { @MainActor [weak self] in
                try? await Task.sleep(
                    for: .milliseconds(DoorControlPresentationContinuity.retentionMilliseconds)
                )
                guard !Task.isCancelled, let self else { return }
                continuity.expire()
                isRetainingControl = false
                expirationTask = nil
            }
        }
    }

    public func reset() {
        expirationTask?.cancel()
        expirationTask = nil
        continuity.expire()
        isRetainingControl = false
    }
}
