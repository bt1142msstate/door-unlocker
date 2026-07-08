import ActivityKit
import SwiftUI

struct FirmwareIslandHeader: View {
    let state: DoorUnlockerActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 6) {
            FirmwareActivityIcon(state: state, size: 16)
            Text(state.firmwareActivityTitle)
                .font(.headline.weight(.bold))
                .foregroundStyle(state.activityColor)
        }
    }
}

struct FirmwareIslandProgress: View {
    let state: DoorUnlockerActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ProgressView(value: state.firmwareProgressFraction, total: 1)
                .tint(state.activityColor)

            Text(state.firmwareStatusText)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
    }
}

struct FirmwareActivityIcon: View {
    let state: DoorUnlockerActivityAttributes.ContentState
    let size: CGFloat

    var body: some View {
        ZStack {
            if state.isFirmwareRunning {
                ProgressView(value: state.firmwareProgressFraction, total: 1)
                    .progressViewStyle(.circular)
                    .tint(state.activityColor)
                    .labelsHidden()
            }

            Image(systemName: state.firmwareSymbolName)
                .font(.system(size: max(7, size * 0.62), weight: .black))
                .foregroundStyle(state.activityColor)
        }
        .frame(width: size * 1.35, height: size * 1.35)
    }
}

struct CompactFirmwareProgressIcon: View {
    let state: DoorUnlockerActivityAttributes.ContentState

    var body: some View {
        FirmwareActivityIcon(state: state, size: 16)
    }
}

extension DoorUnlockerActivityAttributes.ContentState {
    var isFirmwareRunning: Bool {
        isFirmwareUpdate && state != "firmwareComplete" && state != "firmwareFailed"
    }

    var firmwareActivityTitle: String {
        switch state {
        case "firmwareComplete":
            return "Updated"
        case "firmwareFailed":
            return "Failed"
        default:
            return "Updating"
        }
    }

    var firmwareStatusText: String {
        if state == "firmwareComplete", let firmwareVersion {
            return "Controller is on \(firmwareVersion)"
        }

        return firmwareStatus ?? firmwareActivityTitle
    }

    var firmwareProgressText: String {
        guard let firmwareProgress else {
            return state == "firmwareComplete" ? "100%" : "OTA"
        }

        return "\(max(0, min(100, firmwareProgress)))%"
    }

    var firmwareProgressFraction: Double {
        Double(max(0, min(100, firmwareProgress ?? (state == "firmwareComplete" ? 100 : 0)))) / 100
    }

    var firmwareSymbolName: String {
        switch state {
        case "firmwareComplete":
            return "checkmark"
        case "firmwareFailed":
            return "exclamationmark"
        default:
            return "arrow.up"
        }
    }

    var firmwareActivityColor: Color {
        if state == "firmwareFailed" {
            return Color(red: 1.0, green: 0.38, blue: 0.35)
        }

        return state == "firmwareComplete"
            ? Color(red: 0.35, green: 0.86, blue: 0.58)
            : Color(red: 0.63, green: 0.58, blue: 1.0)
    }
}
