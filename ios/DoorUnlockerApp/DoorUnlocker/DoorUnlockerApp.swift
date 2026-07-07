import SwiftUI

@main
struct DoorUnlockerApp: App {
    @StateObject private var controller = DoorUnlockerController()

    init() {
        DoorUnlockerShortcuts.updateAppShortcutParameters()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(controller)
                .preferredColorScheme(.dark)
        }
    }
}
