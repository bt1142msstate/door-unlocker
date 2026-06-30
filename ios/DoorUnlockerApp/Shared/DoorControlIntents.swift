import AppIntents

struct LockDoorIntent: AppIntent {
    static var title: LocalizedStringResource = "Lock Door"
    static var description = IntentDescription("Locks the Door Unlocker controller.")
    static var openAppWhenRun = true
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    func perform() async throws -> some IntentResult {
        DoorCommandStore.request(.lock)
        return .result(dialog: "Locking Door Unlocker")
    }
}

struct UnlockDoorIntent: AppIntent {
    static var title: LocalizedStringResource = "Unlock Door"
    static var description = IntentDescription("Unlocks the Door Unlocker controller.")
    static var openAppWhenRun = true
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    func perform() async throws -> some IntentResult {
        DoorCommandStore.request(.unlock)
        return .result(dialog: "Unlocking Door Unlocker")
    }
}

struct ToggleDoorIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle Lock"
    static var description = IntentDescription("Toggles the Door Unlocker controller between locked and unlocked. Use this for the iPhone Action Button.")
    static var openAppWhenRun = true
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    func perform() async throws -> some IntentResult {
        DoorCommandStore.request(.toggle)
        return .result(dialog: "Toggling Door Unlocker")
    }
}
