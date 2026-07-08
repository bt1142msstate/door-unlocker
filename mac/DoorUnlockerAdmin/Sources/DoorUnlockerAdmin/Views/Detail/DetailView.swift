import DoorUnlockerCore
import SwiftUI
import UniformTypeIdentifiers

struct DetailView: View {
    @ObservedObject var store: DoorAdminStore
    @State private var isFirmwareImporterPresented = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                DetailHeader(store: store)
                HeroControl(store: store)
                ConnectionPanel(store: store)
                LockSettingsPanel(store: store)
                FirmwarePanel(store: store, isImporterPresented: $isFirmwareImporterPresented)
                PairingPanel(store: store)
                DevicesPanel(store: store)
            }
            .padding(26)
        }
        .background(.background)
        .fileImporter(
            isPresented: $isFirmwareImporterPresented,
            allowedContentTypes: [.zip],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result,
                  let url = urls.first else {
                return
            }
            store.startFirmwareUpdate(from: url)
        }
    }
}
