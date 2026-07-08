import SwiftUI
import WidgetKit

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
