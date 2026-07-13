import AppKit
import Foundation

struct HandoffRequest: Sendable {
    let title: String
    let instruction: String
    let spokenPrelude: String
    let spokenAction: String
    let confirmation: String
    let confirmLabel: String
    let countdown: Int
    let symbol: String
    let accent: HandoffAccent

    static func parse(_ arguments: [String]) throws -> HandoffRequest {
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let key = arguments[index]
            guard key.hasPrefix("--"), index + 1 < arguments.count else {
                throw HandoffRequestError.invalidArguments
            }
            values[key] = arguments[index + 1]
            index += 2
        }

        guard
            let title = values["--title"],
            let instruction = values["--instruction"],
            let confirmation = values["--confirmation"],
            let confirmLabel = values["--confirm-label"],
            let countdownText = values["--countdown"],
            let countdown = Int(countdownText),
            0...10 ~= countdown
        else {
            throw HandoffRequestError.invalidArguments
        }

        return HandoffRequest(
            title: title,
            instruction: instruction,
            spokenPrelude: values["--spoken-prelude"] ?? "",
            spokenAction: values["--spoken-action"] ?? "",
            confirmation: confirmation,
            confirmLabel: confirmLabel,
            countdown: countdown,
            symbol: values["--symbol"] ?? "wrench.and.screwdriver.fill",
            accent: HandoffAccent(rawValue: values["--accent"] ?? "blue") ?? .blue
        )
    }
}

enum HandoffRequestError: Error {
    case invalidArguments
}

enum HandoffAccent: String, Sendable {
    case blue
    case green
    case orange
    case pink

    var color: NSColor {
        switch self {
        case .blue: .systemBlue
        case .green: .systemGreen
        case .orange: .systemOrange
        case .pink: .systemPink
        }
    }
}
