import DoorUnlockerCore
import SwiftUI

struct DetailView: View {
    @ObservedObject var store: DoorAdminStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                DetailHeader(store: store)
                HeroControl(store: store)
                ConnectionPanel(store: store)
                LockSettingsPanel(store: store)
                FirmwarePanel(store: store)
                PairingPanel(store: store)
                DevicesPanel(store: store)
            }
            .padding(26)
        }
        .background(.background)
    }
}
