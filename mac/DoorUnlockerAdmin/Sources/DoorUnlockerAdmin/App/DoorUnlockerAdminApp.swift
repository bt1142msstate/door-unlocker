import AppKit
import SwiftUI

@main
struct DoorUnlockerAdminApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var store = DoorAdminAppModel.shared.store

    var body: some Scene {
        WindowGroup("Door Unlocker", id: "main") {
            ContentView(store: store)
                .frame(minWidth: 980, minHeight: 680)
        }
        .defaultSize(width: 1100, height: 760)
        .windowResizability(.contentMinSize)
        .commands {
            DoorAdminCommands(store: store)
        }
    }
}

@MainActor
private final class DoorAdminAppModel {
    static let shared = DoorAdminAppModel()

    let store = DoorAdminStore()
}

private struct DoorAdminCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var store: DoorAdminStore

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Show Door Unlocker") {
                if let window = NSApp.windows.first(where: { $0.title == "Door Unlocker" }) {
                    window.makeKeyAndOrderFront(nil)
                } else {
                    openWindow(id: "main")
                }
                NSApp.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut("n", modifiers: [.command])
        }

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
            .disabled(!store.doorControlPresentation.isPrimaryActionEnabled)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        false
    }
}
