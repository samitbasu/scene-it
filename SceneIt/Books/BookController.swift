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
    /// The window's layout (ADR 0022).
    let preferences: AppPreferences
    /// The open book's page, for the Format menu and the control bar.
    let formatting: EditorFormatting
    let mirror: BackupMirror
    let prompts: any StorePrompts
    private let role: ProcessRole

    /// `prompts` replaces the role's own, for a test that answers from a script.
    init(role: ProcessRole, prompts: (any StorePrompts)? = nil) {
        self.role = role
        let standard: any StorePrompts
        let storage: any PreferenceStorage
        (memory, mirror, standard, storage) = Self.surroundings(for: role)
        preferences = AppPreferences(storage)
        formatting = EditorFormatting(preferences: preferences)
        self.prompts = prompts ?? standard
        store = BookStore(clock: ContinuousClock(), mirror: mirror, memory: memory, prompts: self.prompts)
    }

    /// The writer's own defaults, backup mirror and alerts for the app. The test host and
    /// previews get throwaway ones that never touch the writer's files and never put up a
    /// modal alert nobody can answer.
    private static func surroundings(for role: ProcessRole) -> (
        any BookMemory, BackupMirror, any StorePrompts, any PreferenceStorage
    ) {
        switch role {
        case .app:
            (DefaultsBookMemory(.standard), .standard, AlertPrompts(), DefaultsPreferenceStorage(.standard))
        case .testHost, .preview:
            (
                TransientBookMemory(),
                BackupMirror(
                    root: FileManager.default.temporaryDirectory.appending(path: "Scene It Test Mirror")),
                HeadlessPrompts(),
                TransientPreferenceStorage()
            )
        }
    }

    /// At launch: the books Finder or another launch asked for, or else the last book.
    func launch(opening books: [URL]) async {
        if !books.isEmpty {
            await store.open(books)
        } else if role == .app {
            await store.reopenLastBook()
        }
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
