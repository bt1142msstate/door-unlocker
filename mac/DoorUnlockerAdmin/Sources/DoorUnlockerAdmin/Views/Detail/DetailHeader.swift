import DoorUnlockerCore
import SwiftUI

struct DetailHeader: View {
    @ObservedObject var store: DoorAdminStore

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(store.lockName)
                    .font(.title2.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Label(store.status.modelTitle, systemImage: "rectangle.connected.to.line.below")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            Spacer()
        }
    }
}
