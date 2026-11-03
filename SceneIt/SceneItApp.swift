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
        .defaultSize(WindowMetrics.defaultSize)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            TextEditingCommands()
            BookCommands(books: .shared)
            WindowCommands(books: .shared)
            DiagnosticsCommands(diagnostics: .shared)
        }
    }
}
