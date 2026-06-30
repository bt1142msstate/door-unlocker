import AppKit
import SwiftUI

@main
struct DoorUnlockerAdminApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = DoorAdminStore()

    var body: some Scene {
        WindowGroup("Door Unlocker") {
            ContentView(store: store)
                .frame(minWidth: 980, minHeight: 680)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Controller") {
                Button("Refresh") {
                    store.refreshAll()
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(!store.isConnected || store.isBusy)

                Button(store.status.isUnlocked ? "Lock" : "Unlock") {
                    store.toggleLock()
                }
                .keyboardShortcut("l", modifiers: [.command])
                .disabled(!store.canSendDoorCommand || store.isBusy)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
