import SwiftUI

struct DoorHeaderView: View {
    let lockName: String
    let deviceName: String

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(lockName)
                    .font(.title2.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Label(deviceName, systemImage: "rectangle.connected.to.line.below")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            Spacer()
        }
    }
}
