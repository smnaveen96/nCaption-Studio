import SwiftUI

// MARK: - Main App Entry Point
@main
struct nCaptionStudioApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}
