import SwiftUI

struct ContentView: View {
    var body: some View {
        DoorUnlockerScreen()
    }
}

#Preview {
    ContentView()
        .environmentObject(DoorUnlockerController())
}
