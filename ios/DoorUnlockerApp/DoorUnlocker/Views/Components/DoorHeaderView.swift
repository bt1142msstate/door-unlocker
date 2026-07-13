import SwiftUI

struct DoorHeaderView: View {
    let lockName: String

    var body: some View {
        HStack {
            Text(lockName)
                .font(.title2.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Spacer()
        }
    }
}
