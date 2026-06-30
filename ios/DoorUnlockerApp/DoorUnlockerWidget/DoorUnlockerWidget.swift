import ActivityKit
import SwiftUI
import WidgetKit

struct DoorUnlockerEntry: TimelineEntry {
    let date: Date
    let status: DoorStatusStore.Snapshot
}

struct DoorUnlockerWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> DoorUnlockerEntry {
        DoorUnlockerEntry(date: .now, status: DoorStatusStore.Snapshot(state: "locked", updatedAt: .now, autoLockStartedAt: nil, autoLockDeadline: nil))
    }

    func getSnapshot(in context: Context, completion: @escaping (DoorUnlockerEntry) -> Void) {
        completion(DoorUnlockerEntry(date: .now, status: DoorStatusStore.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<DoorUnlockerEntry>) -> Void) {
        let now = Date()
        let status = DoorStatusStore.load()
        var entries = [DoorUnlockerEntry(date: now, status: status)]

        if status.isUnlocked, let deadline = status.autoLockDeadline, deadline > now {
            let lockedStatus = DoorStatusStore.Snapshot(state: "locked", updatedAt: deadline, autoLockStartedAt: nil, autoLockDeadline: nil)
            entries.append(DoorUnlockerEntry(date: deadline, status: lockedStatus))
        }

        completion(Timeline(entries: entries, policy: .after(Date().addingTimeInterval(15 * 60))))
    }
}

struct DoorUnlockerWidgetView: View {
    let entry: DoorUnlockerEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "door.left.hand.closed")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(statusColor)

                Text("Door Unlocker")
                    .font(.headline.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }

            HStack(spacing: 8) {
                Image(systemName: entry.status.symbolName)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(statusColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.status.title)
                        .font(.title3.weight(.bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)

                    Text(lastUpdatedText)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            commandLink(
                title: entry.status.nextActionTitle,
                icon: entry.status.nextActionSymbolName,
                url: DoorWidgetCommandTokenStore.commandURL(action: entry.status.nextActionName)
            )
        }
        .padding()
        .containerBackground(for: .widget) {
            LinearGradient(
                colors: [
                    Color(red: 0.03, green: 0.05, blue: 0.04),
                    entry.status.isUnlocked ? Color(red: 0.05, green: 0.16, blue: 0.09) : Color(red: 0.05, green: 0.09, blue: 0.14)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private func commandLink(title: String, icon: String, url: URL) -> some View {
        Link(destination: url) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity, minHeight: 40)
                .foregroundStyle(.white)
                .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private var statusColor: Color {
        entry.status.isUnlocked ? Color(red: 0.35, green: 0.86, blue: 0.58) : Color(red: 0.35, green: 0.72, blue: 1.0)
    }

    private var lastUpdatedText: String {
        guard let updatedAt = entry.status.updatedAt else {
            return "Waiting for app"
        }

        return "Updated \(updatedAt.formatted(.relative(presentation: .named)))"
    }
}

struct DoorUnlockerWidget: Widget {
    let kind = "DoorUnlockerWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: DoorUnlockerWidgetProvider()) { entry in
            DoorUnlockerWidgetView(entry: entry)
        }
        .configurationDisplayName("Door Unlocker")
        .description("Quick access to the next lock command.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct DoorUnlockerLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DoorUnlockerActivityAttributes.self) { context in
            LiveActivityView(context: context)
                .activityBackgroundTint(Color(red: 0.03, green: 0.05, blue: 0.04))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        LockStateIcon(state: context.state, size: 16, color: context.state.activityColor)
                        Text(context.state.activityTitle)
                            .font(.headline.weight(.bold))
                            .foregroundStyle(context.state.activityColor)
                    }
                }

                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.isUnlocked {
                        Label("Auto-lock", systemImage: "timer")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(context.state.activityColor)
                    } else {
                        Text(context.state.state == "locking" ? "Closing" : "Done")
                            .font(.headline.weight(.bold))
                            .foregroundStyle(.white)
                    }
                }

                DynamicIslandExpandedRegion(.bottom) {
                    if context.state.isUnlocked {
                        ProgressView(timerInterval: context.state.autoLockTimerRange, countsDown: true) {
                            Text("Auto-lock")
                                .font(.caption.weight(.semibold))
                        }
                        .tint(context.state.activityColor)
                    } else {
                        HStack(spacing: 5) {
                            LockStateIcon(state: context.state, size: 12, color: context.state.activityColor)
                            Text(context.state.lockStatusText)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(context.state.activityColor)
                        }
                    }
                }
            } compactLeading: {
                LockStateIcon(state: context.state, size: 13, color: context.state.activityColor)
            } compactTrailing: {
                if context.state.isUnlocked {
                    CompactCountdownIcon(timerRange: context.state.autoLockTimerRange, color: context.state.activityColor)
                } else {
                    LockStateIcon(state: context.state, size: 11, color: context.state.activityColor)
                }
            } minimal: {
                LockStateIcon(state: context.state, size: 13, color: context.state.activityColor)
            }
        }
    }
}

private struct LockStateIcon: View {
    let state: DoorUnlockerActivityAttributes.ContentState
    let size: CGFloat
    let color: Color

    var body: some View {
        if state.isUnlocked {
            LockGlyph(progress: 0, size: size, color: color)
        } else {
            if let startedAt = state.lockAnimationStartedAt {
                TimelineView(.animation) { timeline in
                    LockGlyph(
                        progress: lockProgress(startedAt: startedAt, now: timeline.date),
                        size: size,
                        color: color
                    )
                }
            } else {
                LockGlyph(progress: fallbackProgress, size: size, color: color)
            }
        }
    }

    private var fallbackProgress: CGFloat {
        switch state.lockIconPhase {
        case 0:
            return 0
        case 1:
            return 0.58
        default:
            return 1
        }
    }

    private func lockProgress(startedAt: Date, now: Date) -> CGFloat {
        let elapsed = now.timeIntervalSince(startedAt)
        return CGFloat(max(0, min(1, elapsed / lockClosureAnimationDuration)))
    }
}

private struct LockGlyph: View {
    let progress: CGFloat
    let size: CGFloat
    let color: Color

    var body: some View {
        let easedProgress = smoothStep(progress)
        let openAmount = 1 - easedProgress
        let settleProgress = max(0, min(1, (progress - 0.82) / 0.18))
        let settle = sin(settleProgress * .pi)
        let shackleAngle = (-36 * openAmount) + (3 * settle)
        let shackleX = size * 0.16 * openAmount
        let shackleY = -size * 0.08 * openAmount
        let bodyScale = 0.96 + (0.04 * easedProgress) + (0.035 * settle)
        let pulseOpacity = max(0, min(1, (progress - 0.76) / 0.24)) * 0.24 * (1 - settleProgress)

        ZStack {
            Circle()
                .stroke(color.opacity(pulseOpacity), lineWidth: max(1, size * 0.08))
                .scaleEffect(0.92 + (0.18 * settleProgress))

            LockShackleShape()
                .stroke(
                    color,
                    style: StrokeStyle(
                        lineWidth: max(1.7, size * 0.13),
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
                .frame(width: size * 0.78, height: size * 0.7)
                .rotationEffect(.degrees(Double(shackleAngle)), anchor: .bottomLeading)
                .offset(x: shackleX, y: shackleY - size * 0.06)

            RoundedRectangle(cornerRadius: max(2, size * 0.14), style: .continuous)
                .fill(color)
                .frame(width: size * 0.88, height: size * 0.58)
                .offset(y: size * 0.18)
                .scaleEffect(bodyScale)
        }
        .frame(width: size * 1.45, height: size * 1.45)
    }

    private func smoothStep(_ value: CGFloat) -> CGFloat {
        let clamped = max(0, min(1, value))
        return clamped * clamped * (3 - (2 * clamped))
    }
}

private struct LockShackleShape: Shape {
    func path(in rect: CGRect) -> Path {
        let leftX = rect.minX + (rect.width * 0.2)
        let rightX = rect.maxX - (rect.width * 0.2)
        let shoulderY = rect.minY + (rect.height * 0.36)
        let bottomY = rect.maxY
        let topY = rect.minY + (rect.height * 0.03)

        var path = Path()
        path.move(to: CGPoint(x: leftX, y: bottomY))
        path.addLine(to: CGPoint(x: leftX, y: shoulderY))
        path.addCurve(
            to: CGPoint(x: rightX, y: shoulderY),
            control1: CGPoint(x: leftX, y: topY),
            control2: CGPoint(x: rightX, y: topY)
        )
        path.addLine(to: CGPoint(x: rightX, y: bottomY))
        return path
    }
}

private let lockClosureAnimationDuration: TimeInterval = 1.25

private struct CompactCountdownIcon: View {
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

private struct LiveActivityView: View {
    let context: ActivityViewContext<DoorUnlockerActivityAttributes>

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(context.state.activityColor.opacity(0.18))
                LockStateIcon(state: context.state, size: 24, color: context.state.activityColor)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 4) {
                Text("Door Unlocker")
                    .font(.headline.weight(.bold))
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

private extension DoorUnlockerActivityAttributes.ContentState {
    var autoLockTimerRange: ClosedRange<Date> {
        let fallbackStartedAt = autoLockDeadline.addingTimeInterval(-30)
        let startedAt = min(autoLockStartedAt ?? fallbackStartedAt, autoLockDeadline.addingTimeInterval(-1))
        return startedAt ... max(autoLockDeadline, startedAt.addingTimeInterval(1))
    }

    var activityTitle: String {
        if state == "locking" {
            return "Locking"
        }

        return isUnlocked ? "Unlocked" : "Locked"
    }

    var lockStatusText: String {
        state == "locking" ? "Locking" : "Locked"
    }

    var lockIconPhase: Int {
        guard !isUnlocked else { return 0 }
        return lockAnimationPhase ?? (state == "locking" ? 1 : 2)
    }

    var symbolName: String {
        isUnlocked ? "lock.open.fill" : "lock.fill"
    }

    var activityColor: Color {
        isUnlocked ? Color(red: 0.35, green: 0.86, blue: 0.58) : Color(red: 0.35, green: 0.72, blue: 1.0)
    }
}

@available(iOSApplicationExtension 18.0, *)
struct DoorUnlockerControl: ControlWidget {
    let kind = "DoorUnlockerControl"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: kind) {
            ControlWidgetButton(action: ToggleDoorIntent()) {
                Label("Toggle Lock", systemImage: "arrow.triangle.2.circlepath")
            }
            .tint(Color(red: 0.35, green: 0.86, blue: 0.58))
        }
        .displayName("Toggle Lock")
        .description("Toggle Door Unlocker from Controls and the Action Button.")
    }
}

@main
struct DoorUnlockerWidgetBundle: WidgetBundle {
    var body: some Widget {
        DoorUnlockerWidget()
        DoorUnlockerLiveActivity()

        if #available(iOSApplicationExtension 18.0, *) {
            DoorUnlockerControl()
        }
    }
}
