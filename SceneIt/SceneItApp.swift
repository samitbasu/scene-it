import SwiftUI

@main
struct SceneItApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            DiagnosticsCommands(diagnostics: .shared)
        }
    }
}
