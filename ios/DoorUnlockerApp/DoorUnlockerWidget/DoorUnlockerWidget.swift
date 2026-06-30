import ActivityKit
import SwiftUI
import WidgetKit

struct DoorUnlockerEntry: TimelineEntry {
    let date: Date
    let status: DoorStatusStore.Snapshot
}

struct DoorUnlockerWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> DoorUnlockerEntry {
        DoorUnlockerEntry(date: .now, status: DoorStatusStore.Snapshot(state: "locked", updatedAt: .now, autoLockDeadline: nil))
    }

    func getSnapshot(in context: Context, completion: @escaping (DoorUnlockerEntry) -> Void) {
        completion(DoorUnlockerEntry(date: .now, status: DoorStatusStore.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<DoorUnlockerEntry>) -> Void) {
        let now = Date()
        let status = DoorStatusStore.load()
        var entries = [DoorUnlockerEntry(date: now, status: status)]

        if status.isUnlocked, let deadline = status.autoLockDeadline, deadline > now {
            let lockedStatus = DoorStatusStore.Snapshot(state: "locked", updatedAt: deadline, autoLockDeadline: nil)
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
                    Label(context.state.activityTitle, systemImage: context.state.symbolName)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(context.state.activityColor)
                        .contentTransition(.symbolEffect(.replace))
                        .symbolEffect(.bounce, value: context.state.state)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.isUnlocked {
                        LiveActivityTimerText(deadline: context.state.autoLockDeadline)
                            .font(.headline.monospacedDigit().weight(.bold))
                            .foregroundStyle(.white)
                    } else {
                        Text("Done")
                            .font(.headline.weight(.bold))
                            .foregroundStyle(.white)
                    }
                }

                DynamicIslandExpandedRegion(.bottom) {
                    if context.state.isUnlocked {
                        ProgressView(timerInterval: timerRange(until: context.state.autoLockDeadline), countsDown: true) {
                            Text("Auto-lock")
                                .font(.caption.weight(.semibold))
                        }
                        .tint(context.state.activityColor)
                    } else {
                        Label("Locked", systemImage: "checkmark.circle.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(context.state.activityColor)
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.symbolName)
                    .foregroundStyle(context.state.activityColor)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.bounce, value: context.state.state)
            } compactTrailing: {
                if context.state.isUnlocked {
                    Image(systemName: "timer")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(context.state.activityColor)
                } else {
                    Image(systemName: "checkmark")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(context.state.activityColor)
                        .contentTransition(.symbolEffect(.replace))
                }
            } minimal: {
                Image(systemName: context.state.symbolName)
                    .foregroundStyle(context.state.activityColor)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.bounce, value: context.state.state)
            }
        }
    }
}

private struct LiveActivityView: View {
    let context: ActivityViewContext<DoorUnlockerActivityAttributes>

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(context.state.activityColor.opacity(0.18))
                Image(systemName: context.state.symbolName)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(context.state.activityColor)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.bounce, value: context.state.state)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 4) {
                Text("Door Unlocker")
                    .font(.headline.weight(.bold))
                HStack(spacing: 4) {
                    if context.state.isUnlocked {
                        Text("Auto-locks in")
                        LiveActivityTimerText(deadline: context.state.autoLockDeadline)
                    } else {
                        Text("Locked")
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(context.state.activityColor)
                            .contentTransition(.symbolEffect(.replace))
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
    let deadline: Date

    var body: some View {
        Text(timerInterval: timerRange(until: deadline), countsDown: true, showsHours: false)
    }
}

private func timerRange(until deadline: Date) -> ClosedRange<Date> {
    let now = Date()
    return now ... max(now, deadline)
}

private extension DoorUnlockerActivityAttributes.ContentState {
    var activityTitle: String {
        isUnlocked ? "Unlocked" : "Locked"
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
