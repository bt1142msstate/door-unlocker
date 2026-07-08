import SwiftUI

enum DoorAppTheme: String, CaseIterable, Identifiable {
    case original
    case monochrome
    case gold
    case aurora
    case pink
    case red
    case ember
    case violet

    var id: String { rawValue }

    var title: String {
        switch self {
        case .original:
            return "Original"
        case .monochrome:
            return "Mono"
        case .gold:
            return "Gold"
        case .aurora:
            return "Aurora"
        case .pink:
            return "Pink"
        case .red:
            return "Red"
        case .ember:
            return "Ember"
        case .violet:
            return "Violet"
        }
    }

    var subtitle: String {
        switch self {
        case .original:
            return "Green / blue"
        case .monochrome:
            return "Black / white"
        case .gold:
            return "Gold / black"
        case .aurora:
            return "Mint / cyan"
        case .pink:
            return "Rose / pink"
        case .red:
            return "Red / ruby"
        case .ember:
            return "Gold / coral"
        case .violet:
            return "Lilac / indigo"
        }
    }

    var unlockedColor: Color {
        switch self {
        case .original:
            return Color(red: 0.35, green: 0.86, blue: 0.58)
        case .monochrome:
            return Color(red: 0.96, green: 0.97, blue: 0.94)
        case .gold:
            return Color(red: 1.00, green: 0.78, blue: 0.24)
        case .aurora:
            return Color(red: 0.30, green: 0.92, blue: 0.72)
        case .pink:
            return Color(red: 1.00, green: 0.45, blue: 0.74)
        case .red:
            return Color(red: 1.00, green: 0.30, blue: 0.34)
        case .ember:
            return Color(red: 1.00, green: 0.70, blue: 0.30)
        case .violet:
            return Color(red: 0.80, green: 0.58, blue: 1.00)
        }
    }

    var lockedColor: Color {
        switch self {
        case .original:
            return Color(red: 0.35, green: 0.72, blue: 1.0)
        case .monochrome:
            return Color(red: 0.64, green: 0.66, blue: 0.62)
        case .gold:
            return Color(red: 0.95, green: 0.50, blue: 0.10)
        case .aurora:
            return Color(red: 0.34, green: 0.76, blue: 1.0)
        case .pink:
            return Color(red: 0.82, green: 0.35, blue: 1.00)
        case .red:
            return Color(red: 0.72, green: 0.08, blue: 0.18)
        case .ember:
            return Color(red: 1.00, green: 0.40, blue: 0.30)
        case .violet:
            return Color(red: 0.44, green: 0.48, blue: 1.00)
        }
    }

    var backgroundTail: Color {
        switch self {
        case .original:
            return Color(red: 0.09, green: 0.07, blue: 0.05)
        case .monochrome:
            return Color(red: 0.00, green: 0.00, blue: 0.00)
        case .gold:
            return Color(red: 0.10, green: 0.07, blue: 0.02)
        case .aurora:
            return Color(red: 0.02, green: 0.09, blue: 0.08)
        case .pink:
            return Color(red: 0.13, green: 0.04, blue: 0.10)
        case .red:
            return Color(red: 0.13, green: 0.03, blue: 0.04)
        case .ember:
            return Color(red: 0.12, green: 0.06, blue: 0.03)
        case .violet:
            return Color(red: 0.08, green: 0.05, blue: 0.13)
        }
    }

    func accent(isUnlocked: Bool) -> Color {
        isUnlocked ? unlockedColor : lockedColor
    }
}
