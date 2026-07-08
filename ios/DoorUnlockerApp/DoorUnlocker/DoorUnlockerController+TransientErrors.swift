extension DoorUnlockerController {
    func shouldHideTransientStartupError(_ error: String) -> Bool {
        guard canAcceptDoorCommand || isDoorCommandQueuedForSecureLink || isPreparingKnownController else {
            return false
        }

        return error.containsAnyLowercaseFragment([
            "not connected",
            "connect failed",
            "connection timed out",
            "peripheral disconnected",
            "required controller characteristic not found",
            "fresh secure command"
        ])
    }

    func shouldHideFirmwareUpdateTransientError(_ error: String) -> Bool {
        guard shouldSuppressFirmwareUpdateTransientErrors else { return false }

        return error.containsAnyLowercaseFragment([
            "not connected",
            "connect failed",
            "connection timed out",
            "peripheral disconnected",
            "required controller characteristic not found",
            "door service not found",
            "fresh secure command"
        ])
    }
}

private extension String {
    func containsAnyLowercaseFragment(_ fragments: [String]) -> Bool {
        let normalizedValue = lowercased()
        return fragments.contains { normalizedValue.contains($0) }
    }
}
