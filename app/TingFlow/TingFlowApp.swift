import SwiftUI

@main
struct TingFlowApp: App {
    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-TingFlowServerCoverFixture") {
                ServerArtworkPreviewFixture()
            } else {
                ContentView().preferredColorScheme(nil)
            }
            #else
            ContentView().preferredColorScheme(nil)
            #endif
        }
    }
}
