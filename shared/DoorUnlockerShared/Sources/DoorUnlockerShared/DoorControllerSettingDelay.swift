public enum DoorControllerSettingDelay {
    public static let inputDebounceNanoseconds: UInt64 = 250_000_000
    public static let busyRetryNanoseconds: UInt64 = 750_000_000

    public static func wait(nanoseconds: UInt64) async -> Bool {
        do {
            try await Task.sleep(nanoseconds: nanoseconds)
            return !Task.isCancelled
        } catch {
            return false
        }
    }
}
