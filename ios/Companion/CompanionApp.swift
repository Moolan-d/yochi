import SwiftUI

@main
struct CompanionApp: App {
    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if SampleConversationView.requested {
                SampleConversationView()
            } else {
                ContentView()
            }
            #else
            ContentView()
            #endif
        }
    }
}
