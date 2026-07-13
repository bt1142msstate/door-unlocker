import DoorUnlockerCore
import SwiftUI

struct DetailHeader: View {
    @ObservedObject var store: DoorAdminStore

    var body: some View {
        HStack {
            Text(store.lockName)
                .font(.title2.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Spacer()
        }
    }
}
