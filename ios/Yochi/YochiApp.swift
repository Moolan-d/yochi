import SwiftUI

@main
struct YochiApp: App {
    init() {
        #if DEBUG
        HangMeter.shared.start()
        #endif
    }

    @AppStorage(Appearance.key) private var appearance: Appearance = .system

    var body: some Scene {
        WindowGroup {
            root.preferredColorScheme(appearance.colorScheme)
        }
    }

    @ViewBuilder private var root: some View {
        #if DEBUG
        if SampleConversationView.requested {
            SampleConversationView()
        } else if SampleHomeView.requested {
            SampleHomeView()
        } else {
            ContentView()
        }
        #else
        ContentView()
        #endif
    }
}
