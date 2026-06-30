import AppIntents

struct DoorUnlockerShortcuts: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor = .lime

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ToggleDoorIntent(),
            phrases: [
                "Toggle lock with \(.applicationName)",
                "Toggle the lock with \(.applicationName)",
                "Toggle \(.applicationName)"
            ],
            shortTitle: "Toggle Lock",
            systemImageName: "arrow.triangle.2.circlepath"
        )

        AppShortcut(
            intent: UnlockDoorIntent(),
            phrases: [
                "Unlock \(.applicationName)",
                "Unlock the door with \(.applicationName)",
                "\(.applicationName) unlock"
            ],
            shortTitle: "Unlock Door",
            systemImageName: "lock.open.fill"
        )

        AppShortcut(
            intent: LockDoorIntent(),
            phrases: [
                "Lock \(.applicationName)",
                "Lock the door with \(.applicationName)",
                "\(.applicationName) lock"
            ],
            shortTitle: "Lock Door",
            systemImageName: "lock.fill"
        )
    }
}
