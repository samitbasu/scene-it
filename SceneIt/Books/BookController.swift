import AppKit
import SceneItCore

typealias AppBookStore = BookStore<ContinuousClock>

/// The app's side of the `BookStore`: the panels for New and Open, books AppKit asks us to
/// open, and the store built for this kind of process. There is one per process, as there is
/// one main window (ADR 0021).
final class BookController {
    static let shared = BookController(role: .current)

    let store: AppBookStore
    let memory: any BookMemory
    let mirror: BackupMirror
    private let role: ProcessRole

    init(role: ProcessRole, prompts: any StorePrompts = AlertPrompts()) {
        self.role = role
        (memory, mirror) = Self.persistence(for: role)
        store = BookStore(clock: ContinuousClock(), mirror: mirror, memory: memory, prompts: prompts)
    }

    /// The writer's own defaults and backup mirror for the app; throwaway ones for the test
    /// host and previews, which must never touch the writer's files.
    private static func persistence(for role: ProcessRole) -> (any BookMemory, BackupMirror) {
        switch role {
        case .app:
            (DefaultsBookMemory(.standard), .standard)
        case .testHost, .preview:
            (
                TransientBookMemory(),
                BackupMirror(
                    root: FileManager.default.temporaryDirectory.appending(path: "Scene It Test Mirror"))
            )
        }
    }

    /// At launch: the books Finder or another launch asked for, or else the last book.
    func launch(opening books: [URL]) async {
        if !books.isEmpty {
            await open(books)
        } else if role == .app {
            await store.reopenLastBook()
        }
    }

    /// One book at a time (ADR 0021): of several, only the first is opened.
    func open(_ books: [URL]) async {
        guard let first = books.first else { return }
        if books.count > 1 {
            Log.app.info("asked to open several books; opening the first", ["count": .count(books.count)])
        }
        await store.open(first)
    }

    func newBook() async {
        while true {
            let panel = NSSavePanel()
            panel.title = StoreWording.newBookPanelTitle
            panel.prompt = StoreWording.newBookPanelPrompt
            panel.nameFieldStringValue = StoreWording.newBookDefaultName
            panel.allowedContentTypes = [.sceneItBook]
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return }
            guard case .failed(.alreadyExists) = await store.create(at: url) else { return }
        }
    }

    func openBook() async {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.sceneItBook]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        await store.open(url)
    }
}
