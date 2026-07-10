import ActivityKit
import SwiftUI
import WidgetKit

struct LockStateIcon: View {
    let state: DoorUnlockerActivityAttributes.ContentState
    let size: CGFloat
    let color: Color

    var body: some View {
        LockSymbol(name: pose.symbolName, size: size, color: color, flipDegrees: pose.flipDegrees)
            .animation(.easeInOut(duration: lockFlipAnimationHalfDuration), value: state.lockIconPhase)
            .animation(.easeInOut(duration: lockFlipAnimationHalfDuration), value: state.state)
    }

    private var pose: LockIconPose {
        guard !state.isUnlocked else {
            return LockIconPose(symbolName: "lock.open.fill", flipDegrees: 0)
        }

        switch state.lockIconPhase {
        case 0:
            return LockIconPose(symbolName: "lock.open.fill", flipDegrees: 0)
        case 1:
            return LockIconPose(symbolName: "lock.open.fill", flipDegrees: 88)
        case 2:
            return LockIconPose(symbolName: "lock.fill", flipDegrees: -88)
        default:
            return LockIconPose(symbolName: "lock.fill", flipDegrees: 0)
        }
    }
}

private struct LockIconPose {
    let symbolName: String
    let flipDegrees: Double
}

private struct LockSymbol: View {
    let name: String
    let size: CGFloat
    let color: Color
    let flipDegrees: Double

    var body: some View {
        Image(systemName: name)
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(color)
            .rotation3DEffect(
                .degrees(flipDegrees),
                axis: (x: 0, y: 1, z: 0),
                perspective: 0.55
            )
            .frame(width: size * 1.35, height: size * 1.35)
    }
}

private let lockFlipAnimationHalfDuration: TimeInterval = 0.42

struct CompactCountdownIcon: View {
    let timerRange: ClosedRange<Date>
    let color: Color

    var body: some View {
        ZStack {
            ProgressView(timerInterval: timerRange, countsDown: true)
                .progressViewStyle(.circular)
                .tint(color)
                .labelsHidden()

            Image(systemName: "timer")
                .font(.system(size: 8, weight: .black))
                .foregroundStyle(color)
        }
        .frame(width: 18, height: 18)
    }
}

struct LiveActivityView: View {
    let context: ActivityViewContext<DoorUnlockerActivityAttributes>

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(context.state.activityColor.opacity(0.18))
                if context.state.isFirmwareUpdate {
                    FirmwareActivityIcon(state: context.state, size: 28)
                } else {
                    LockStateIcon(state: context.state, size: 24, color: context.state.activityColor)
                }
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 4) {
                Text(context.attributes.title)
                    .font(.headline.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                if context.state.isFirmwareUpdate {
                    Text(context.state.firmwareStatusText)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)

                    ProgressView(value: context.state.firmwareProgressFraction, total: 1)
                        .tint(context.state.activityColor)

                    if let etaText = context.state.firmwareEtaText {
                        Text(etaText)
                            .font(.caption.monospacedDigit().weight(.bold))
                            .foregroundStyle(context.state.activityColor)
                            .lineLimit(1)
                    }
                } else {
                    HStack(spacing: 4) {
                        if context.state.isUnlocked {
                            Text("Auto-locks in")
                            LiveActivityTimerText(timerRange: context.state.autoLockTimerRange)
                        } else {
                            Text(context.state.lockStatusText)
                            LockStateIcon(state: context.state, size: 13, color: context.state.activityColor)
                        }
                    }
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)
        }
        .padding(16)
    }
}

private struct LiveActivityTimerText: View {
    let timerRange: ClosedRange<Date>

    var body: some View {
        Text(timerInterval: timerRange, countsDown: true, showsHours: false)
    }
}
