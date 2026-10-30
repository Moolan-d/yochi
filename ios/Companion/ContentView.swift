import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView("尚未连接 Gateway", systemImage: "network.slash")
                .navigationTitle("Companion")
        }
    }
}

#Preview {
    ContentView()
}
