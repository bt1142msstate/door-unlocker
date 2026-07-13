import DoorUnlockerCore
import SwiftUI

struct ControllerStatusStrip: View {
    @ObservedObject var store: DoorAdminStore
    let tint: Color

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: store.controllerStatusSymbol)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(store.controllerStatusTitle)
                    .font(.caption.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                Text(store.controllerStatusDetail)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
