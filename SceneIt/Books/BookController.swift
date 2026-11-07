import AppKit
import SceneItCore

typealias AppBookStore = BookStore<ContinuousClock>

/// The app's side of the `BookStore`: the panels for New and Open, books AppKit asks us to
/// open, Close Book, and the store built for this kind of process. There is one per process,
/// as there is one main window and one book (ADR 0038).
@Observable
final class BookController {
    static let shared = BookController(role: .current)

    /// Before a book is chosen, the close button quits; whether File → Close Book does too is
    /// the owner's to decide (ADR 0038).
    enum StartStateClosing {
        case closeButtonOnly
        case closeButtonAndMenu
    }

    static let startStateClosing = StartStateClosing.closeButtonOnly

    /// Replaced only in the test host, which stands in for many launches (`startOver`).
    private(set) var store: AppBookStore
    @ObservationIgnored let memory: any BookMemory
    /// The window's layout (ADR 0022).
    @ObservationIgnored let preferences: AppPreferences
    /// The open book's page, for the Format menu and the control bar.
    @ObservationIgnored let formatting: EditorFormatting
    @ObservationIgnored let mirror: BackupMirror
    @ObservationIgnored let prompts: any StorePrompts
    @ObservationIgnored let requests: AppRequests
    /// The test host's and previews' record of `requests`; nil in the app.
    @ObservationIgnored let recorded: RecordedRequests?
    @ObservationIgnored private let role: ProcessRole

    /// `prompts` replaces the role's own, for a test that answers from a script.
    init(role: ProcessRole, prompts: (any StorePrompts)? = nil) {
        self.role = role
        let standard: any StorePrompts
        let storage: any PreferenceStorage
        (memory, mirror, standard, storage, recorded) = Self.surroundings(for: role)
        requests = AppRequests(carryOut: recorded.map { recorder in recorder.record } ?? AppRequests.appKit)
        preferences = AppPreferences(storage)
        formatting = EditorFormatting(preferences: preferences)
        self.prompts = prompts ?? standard
        store = Self.makeStore(memory: memory, mirror: mirror, prompts: self.prompts, requests: requests)
        recorded?.storeIsBusy = { [unowned self] in store.isBusy }
    }

    /// The writer's own defaults, backup mirror and alerts for the app. The test host and
    /// previews get throwaway ones that never touch the writer's files, never put up a modal
    /// alert nobody can answer, and never quit the process they run in.
    private static func surroundings(for role: ProcessRole) -> (
        any BookMemory, BackupMirror, any StorePrompts, any PreferenceStorage, RecordedRequests?
    ) {
        switch role {
        case .app:
            (
                DefaultsBookMemory(.standard), .standard, AlertPrompts(),
                DefaultsPreferenceStorage(.standard), nil
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
        memory: any BookMemory, mirror: BackupMirror, prompts: any StorePrompts, requests: AppRequests
    ) -> AppBookStore {
        BookStore(
            clock: ContinuousClock(), mirror: mirror, memory: memory, prompts: prompts,
            bookLost: { requests.send(.quit) })
    }

    #if DEBUG
        /// The test host's relaunch: a new session once the last one has ended. The app never
        /// starts over; its process ends with its session (ADR 0038).
        func startOver() {
            precondition(role != .app, "only the test host starts a new session")
            guard case .ended = store.session else {
                preconditionFailure("a session starts over only once it has ended")
            }
            store = Self.makeStore(memory: memory, mirror: mirror, prompts: prompts, requests: requests)
        }
    #endif

    /// The window showing this controller's book, known by the close button `MainWindow` routes.
    var mainWindow: NSWindow? {
        NSApp.windows.first {
            ($0.standardWindowButton(.closeButton)?.target as? CloseButtonQuits.Router)?.books === self
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

    /// Books Finder or another launch sent while Scene It runs (ADR 0020). The window comes
    /// forward; the store opens them only if the process has no book yet (ADR 0038).
    func openForwarded(_ books: [URL]) async {
        requests.send(.bringForward(mainWindow))
        await store.open(books)
    }

    /// The window's close button, and Close Book while the book's window is key: both are Quit
    /// (ADR 0038).
    func closeBook() {
        requests.send(.quit)
    }

    var isCloseBookEnabled: Bool {
        switch Self.startStateClosing {
        case .closeButtonOnly: store.current != nil
        case .closeButtonAndMenu: store.current != nil || store.isChoosing
        }
    }

    enum CloseTarget: Equatable {
        case book
        case window(NSWindow)
    }

    /// File → Close Book (⌘W) closes the book only from the book's own window (or a sheet on
    /// it, or with no key window); from any other window, ⌘W closes that window.
    func closeTarget(keyWindow: NSWindow?) -> CloseTarget {
        guard let keyWindow, (keyWindow.sheetParent ?? keyWindow) !== mainWindow else { return .book }
        return .window(keyWindow)
    }

    func closeFromMenu() {
        switch closeTarget(keyWindow: NSApp.keyWindow) {
        case .book: closeBook()
        case .window(let window): window.performClose(nil)
        }
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
    /// The app comes forward, with the main window if there is one.
    case bringForward(NSWindow?)
}

/// Carries out the controller's requests through `carryOut`: AppKit in the app, a recorder in
/// the test host. Quitting starts from a run-loop source, never in the sender's own turn:
/// `terminate` runs a nested run loop until the quit path (a main-actor task) replies, and that
/// task can't start while the sender's main-queue job, or a store operation, is still running.
final class AppRequests: NSObject {
    private let carryOut: (AppRequest) -> Void

    init(carryOut: @escaping (AppRequest) -> Void) {
        self.carryOut = carryOut
    }

    func send(_ request: AppRequest) {
        switch request {
        case .quit:
            perform(#selector(quitNow), with: nil, afterDelay: 0)
        case .bringForward:
            carryOut(request)
        }
    }

    @objc private func quitNow() {
        carryOut(.quit)
    }

    static func appKit(_ request: AppRequest) {
        switch request {
        case .quit:
            NSApp.terminate(nil)
        case .bringForward(let window):
            NSApp.activate()
            guard let window else { return }
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }
    }
}

/// For the test host and previews, where quitting would end the run: records each request as
/// it would have been carried out, with whether the store was inside an operation then.
final class RecordedRequests {
    struct Carried: Hashable {
        let request: AppRequest
        let storeWasBusy: Bool
    }

    private(set) var carried: [Carried] = []
    var storeIsBusy: () -> Bool = { false }

    func record(_ request: AppRequest) {
        carried.append(Carried(request: request, storeWasBusy: storeIsBusy()))
    }

    /// The requests so far, which are then forgotten.
    func take() -> [Carried] {
        defer { carried = [] }
        return carried
    }
}
