import AppKit
import SwiftUI

@main
struct DoorUnlockerHandoffApp: App {
    @NSApplicationDelegateAdaptor(HandoffAppDelegate.self) private var appDelegate
    private let request: HandoffRequest

    init() {
        do {
            request = try HandoffRequest.parse(Array(CommandLine.arguments.dropFirst()))
        } catch {
            FileHandle.standardError.write(
                Data("Invalid physical handoff arguments.\n".utf8)
            )
            exit(2)
        }
    }

    var body: some Scene {
        WindowGroup {
            HandoffView(coordinator: HandoffCoordinator(request: request))
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}

final class HandoffAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            guard let window = NSApp.windows.first else { return }
            window.level = .floating
            window.center()
            window.standardWindowButton(.closeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        exit(HandoffRuntime.exitCode)
    }
}
