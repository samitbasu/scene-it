import SceneItCore
import SwiftUI

@main
struct SceneItApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// One window, holding one book at a time (ADR 0038).
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
            CommentCommands(formatting: BookController.shared.formatting)
            FormatCommands(formatting: BookController.shared.formatting)
            DiagnosticsCommands(diagnostics: .shared)
        }
    }
}
