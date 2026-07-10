import AppKit
import SwiftUI

@main
struct DoorUnlockerAdminApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var store = DoorAdminAppModel.shared.store

    init() {
        DispatchQueue.main.async {
            DoorAdminMainWindowPresenter.shared.show(store: DoorAdminAppModel.shared.store)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Show Door Unlocker") {
                    DoorAdminMainWindowPresenter.shared.show(store: store)
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
}

@MainActor
private final class DoorAdminAppModel {
    static let shared = DoorAdminAppModel()

    let store = DoorAdminStore()
}

@MainActor
private final class DoorAdminMainWindowPresenter {
    static let shared = DoorAdminMainWindowPresenter()

    private var window: NSWindow?

    func show(store: DoorAdminStore) {
        if window == nil {
            let rootView = ContentView(store: store)
                .frame(minWidth: 980, minHeight: 680)
            let hostingController = NSHostingController(rootView: rootView)
            let nextWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            nextWindow.title = "Door Unlocker"
            nextWindow.contentViewController = hostingController
            nextWindow.contentMinSize = NSSize(width: 980, height: 680)
            nextWindow.isReleasedWhenClosed = false
            nextWindow.center()
            window = nextWindow
        }

        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            DoorAdminMainWindowPresenter.shared.show(store: DoorAdminAppModel.shared.store)
        }
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
