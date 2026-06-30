import AppIntents

struct LockDoorIntent: AppIntent {
    static var title: LocalizedStringResource = "Lock Door"
    static var description = IntentDescription("Locks the Door Unlocker controller.")
    static var openAppWhenRun = true
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    func perform() async throws -> some IntentResult & ProvidesDialog {
        DoorCommandStore.request(.lock)
        return .result(dialog: "Door Unlocker is locking.")
    }
}

struct UnlockDoorIntent: AppIntent {
    static var title: LocalizedStringResource = "Unlock Door"
    static var description = IntentDescription("Unlocks the Door Unlocker controller.")
    static var openAppWhenRun = true
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    func perform() async throws -> some IntentResult & ProvidesDialog {
        DoorCommandStore.request(.unlock)
        return .result(dialog: "Door Unlocker is unlocking.")
    }
}

struct ToggleDoorIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle Lock"
    static var description = IntentDescription("Toggles the Door Unlocker controller between locked and unlocked. Use this for the iPhone Action Button.")
    static var openAppWhenRun = true
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let snapshot = DoorStatusStore.load()

        if snapshot.isUnlocked {
            DoorCommandStore.request(.lock)
            return .result(dialog: "Door Unlocker is locking.")
        }

        if snapshot.state == "locked" || snapshot.state == "locking" {
            DoorCommandStore.request(.unlock)
            return .result(dialog: "Door Unlocker is unlocking.")
        }

        DoorCommandStore.request(.toggle)
        return .result(dialog: "Door Unlocker is toggling.")
    }
}
