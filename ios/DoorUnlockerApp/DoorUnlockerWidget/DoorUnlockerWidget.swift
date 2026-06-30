import SwiftUI
import WidgetKit

struct DoorUnlockerEntry: TimelineEntry {
    let date: Date
    let status: DoorStatusStore.Snapshot
}

struct DoorUnlockerWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> DoorUnlockerEntry {
        DoorUnlockerEntry(date: .now, status: DoorStatusStore.Snapshot(state: "locked", updatedAt: .now))
    }

    func getSnapshot(in context: Context, completion: @escaping (DoorUnlockerEntry) -> Void) {
        completion(DoorUnlockerEntry(date: .now, status: DoorStatusStore.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<DoorUnlockerEntry>) -> Void) {
        let entry = DoorUnlockerEntry(date: .now, status: DoorStatusStore.load())
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(15 * 60))))
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

        if #available(iOSApplicationExtension 18.0, *) {
            DoorUnlockerControl()
        }
    }
}
