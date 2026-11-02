import SceneItCore
import SwiftUI

@main
struct SceneItApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// One window, holding at most one book (ADR 0021).
    var body: some Scene {
        Window(StoreWording.windowTitle, id: "main") {
            MainWindow(books: .shared)
        }
        .defaultSize(width: 1440, height: 900)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            BookCommands(books: .shared)
            WindowCommands(books: .shared)
            DiagnosticsCommands(diagnostics: .shared)
        }
    }
}
