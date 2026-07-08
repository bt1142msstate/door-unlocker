import DoorUnlockerCore
import SwiftUI

struct ContentView: View {
    @ObservedObject var store: DoorAdminStore

    var body: some View {
        NavigationSplitView {
            SidebarView(store: store)
                .navigationSplitViewColumnWidth(min: 260, ideal: 292)
        } detail: {
            DetailView(store: store)
        }
    }
}
