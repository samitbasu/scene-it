import AppKit
import SceneItCore

typealias AppBookStore = BookStore<ContinuousClock>

/// The app's side of the `BookStore`: the panels for New and Open, books AppKit asks us to
/// open, Close Book, and the store built for this kind of process. There is one per process,
/// as there is one main window and one book (ADR 0038).
@Observable
final class BookController {
    static let shared = BookController(role: .current)

    /// Replaced only in the test host, which stands in for many launches (`startOver`).
    private(set) var store: AppBookStore
    @ObservationIgnored let memory: any BookMemory
    /// The window's layout (ADR 0022).
    @ObservationIgnored let preferences: AppPreferences
    /// The open book's page, for the Format menu and the control bar.
    @ObservationIgnored let formatting: EditorFormatting
    @ObservationIgnored let mirror: BackupMirror
    @ObservationIgnored let prompts: any StorePrompts
    @ObservationIgnored let requests: any AppRequests
    @ObservationIgnored private let role: ProcessRole

    /// `prompts` replaces the role's own, for a test that answers from a script.
    init(role: ProcessRole, prompts: (any StorePrompts)? = nil) {
        self.role = role
        let standard: any StorePrompts
        let storage: any PreferenceStorage
        (memory, mirror, standard, storage, requests) = Self.surroundings(for: role)
        preferences = AppPreferences(storage)
        formatting = EditorFormatting(preferences: preferences)
        self.prompts = prompts ?? standard
        store = Self.makeStore(memory: memory, mirror: mirror, prompts: self.prompts, requests: requests)
    }

    /// The writer's own defaults, backup mirror and alerts for the app. The test host and
    /// previews get throwaway ones that never touch the writer's files, never put up a modal
    /// alert nobody can answer, and never quit the process they run in.
    private static func surroundings(for role: ProcessRole) -> (
        any BookMemory, BackupMirror, any StorePrompts, any PreferenceStorage, any AppRequests
    ) {
        switch role {
        case .app:
            (
                DefaultsBookMemory(.standard), .standard, AlertPrompts(),
                DefaultsPreferenceStorage(.standard),
                AppKitRequests()
            )
        case .testHost, .preview:
            (
                TransientBookMemory(),
                BackupMirror(
                    root: FileManager.default.temporaryDirectory.appending(path: "Scene It Test Mirror")),
                HeadlessPrompts(),
                TransientPreferenceStorage(),
                RecordedRequests()
            )
        }
    }

    /// A book lost while open (ADR 0018's other version wouldn't open) leaves the process
    /// nothing to do, so it quits as Close Book does.
    private static func makeStore(
        memory: any BookMemory, mirror: BackupMirror, prompts: any StorePrompts, requests: any AppRequests
    ) -> AppBookStore {
        BookStore(
            clock: ContinuousClock(), mirror: mirror, memory: memory, prompts: prompts,
            bookLost: { requests.send(.quit) })
    }

    /// The test host's relaunch: a new session once the last one has ended. The app never
    /// starts over; its process ends with its session (ADR 0038).
    func startOver() {
        precondition(role != .app, "only the test host starts a new session")
        guard case .ended = store.session else {
            preconditionFailure("a session starts over only once it has ended")
        }
        store = Self.makeStore(memory: memory, mirror: mirror, prompts: prompts, requests: requests)
    }

    /// At launch: the books Finder or another launch asked for, or else the last book.
    func launch(opening books: [URL]) async {
        if !books.isEmpty {
            await store.open(books)
        } else if role == .app {
            await store.reopenLastBook()
        }
    }

    /// Books Finder or another launch sent while Scene It runs (ADR 0020). The window comes
    /// forward; the store opens them only if the process has no book yet (ADR 0038).
    func openForwarded(_ books: [URL]) async {
        requests.send(.bringWindowForward)
        await store.open(books)
    }

    /// Close Book, and the window's close button: both are Quit (ADR 0038).
    func closeBook() {
        requests.send(.quit)
    }

    func newBook() async {
        while store.isChoosing {
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
        guard store.isChoosing else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.sceneItBook]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        await store.open(url)
    }
}

/// What the controller asks of the whole app. Quitting goes through AppKit's own path
/// (`applicationShouldTerminate`), so Close Book and closing the window ask exactly what Quit
/// asks (ADR 0038).
enum AppRequest: Hashable {
    case quit
    case bringWindowForward
}

protocol AppRequests: AnyObject {
    func send(_ request: AppRequest)
}

final class AppKitRequests: AppRequests {
    func send(_ request: AppRequest) {
        switch request {
        case .quit:
            NSApp.terminate(nil)
        case .bringWindowForward:
            NSApp.activate()
            guard let window = NSApp.windows.first(where: { $0.canBecomeMain && !($0 is NSPanel) }) else {
                return
            }
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }
    }
}

/// For the test host and previews, where quitting would end the run: records each request.
final class RecordedRequests: AppRequests {
    private(set) var sent: [AppRequest] = []

    func send(_ request: AppRequest) {
        sent.append(request)
    }

    /// The requests so far, which are then forgotten.
    func take() -> [AppRequest] {
        defer { sent = [] }
        return sent
    }
}
