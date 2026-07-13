import AppKit
import Foundation
import SwiftUI

@MainActor
final class HandoffCoordinator: ObservableObject {
    enum Phase: Equatable {
        case ready
        case counting(Int)
        case awaitingConfirmation
        case completing
    }

    @Published private(set) var phase: Phase = .ready
    let request: HandoffRequest

    private var started = false

    init(request: HandoffRequest) {
        self.request = request
    }

    var primaryLabel: String {
        switch phase {
        case .ready:
            request.countdown > 0 ? "Start countdown" : request.confirmLabel
        case .counting:
            "Get ready"
        case .awaitingConfirmation:
            request.confirmLabel
        case .completing:
            "Done"
        }
    }

    var primaryEnabled: Bool {
        if case .counting = phase { return false }
        return phase != .completing
    }

    func begin() {
        guard !started else { return }
        started = true
        if request.countdown == 0 {
            Task {
                await speak(request.spokenPrelude)
                phase = .awaitingConfirmation
            }
        }
    }

    func performPrimaryAction() {
        switch phase {
        case .ready where request.countdown > 0:
            Task { await runCountdown() }
        case .ready, .awaitingConfirmation:
            complete()
        case .counting, .completing:
            break
        }
    }

    func cancel() {
        HandoffRuntime.exitCode = 130
        NSApp.terminate(nil)
    }

    private func runCountdown() async {
        await speak(request.spokenPrelude)
        for value in stride(from: request.countdown, through: 1, by: -1) {
            withAnimation(.snappy(duration: 0.22)) {
                phase = .counting(value)
            }
            await speak(String(value))
            try? await Task.sleep(for: .milliseconds(280))
        }
        await speak(request.spokenAction)
        withAnimation(.snappy(duration: 0.28)) {
            phase = .awaitingConfirmation
        }
    }

    private func complete() {
        withAnimation(.snappy(duration: 0.25)) {
            phase = .completing
        }
        HandoffRuntime.exitCode = 0
        Task {
            try? await Task.sleep(for: .milliseconds(420))
            NSApp.terminate(nil)
        }
    }

    private func speak(_ text: String) async {
        guard !text.isEmpty else { return }
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            process.arguments = [text]
            try? process.run()
            process.waitUntilExit()
        }.value
    }
}

@MainActor
enum HandoffRuntime {
    static var exitCode: Int32 = 130
}
