import SwiftUI

@main
struct CompanionApp: App {
    init() {
        #if DEBUG
        HangMeter.shared.start()
        #endif
    }

    var body: some Scene {
        WindowGroup {
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
}
