import SwiftUI

@main
struct DoorUnlockerApp: App {
    init() {
        DoorUnlockerShortcuts.updateAppShortcutParameters()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
        }
    }
}
