import AppKit
import SceneItCore

typealias AppBookStore = BookStore<ContinuousClock>

/// The app's side of the `BookStore`: the panels for New and Open, books AppKit asks us to
/// open, closing the book or the window, and the store built for this kind of process. There
/// is one per process, as there is one main window (ADR 0038).
final class BookController {
    static let shared = BookController(role: .current)

    /// What ⌘W does on the start screen, where the window's close button quits: the owner's
    /// to decide (ADR 0038).
    enum StartScreenCommandW {
        case quits
        case nothing
    }

    static let startScreenCommandW = StartScreenCommandW.quits

    let store: AppBookStore
    /// The close a press started, until it has finished: any press meanwhile does nothing, even
    /// one decided before the store reached `closing` (while another operation held it).
    private var closeInFlight: Task<Void, Never>?
    let memory: any BookMemory
    /// The window's layout (ADR 0022).
    let preferences: AppPreferences
    /// The open book's page, for the Format menu and the control bar.
    let formatting: EditorFormatting
    let mirror: BackupMirror
    let prompts: any StorePrompts
    let requests: AppRequests
    /// The test host's and previews' record of `requests`; nil in the app.
    let recorded: RecordedRequests?
    private let role: ProcessRole

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
        store = BookStore(clock: ContinuousClock(), mirror: mirror, memory: memory, prompts: self.prompts)
        recorded?.storeIsBusy = { [store] in store.isBusy }
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

    /// The window showing this controller's book or start screen, known by the close button
    /// `MainWindow` routes to it.
    var mainWindow: NSWindow? {
        NSApp.windows.first {
            ($0.standardWindowButton(.closeButton)?.target as? MainWindowCloseButton.Router)?.books === self
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
    /// forward; the store opens them only from the start screen (ADR 0038).
    func openForwarded(_ books: [URL]) async {
        requests.send(.bringForward(mainWindow))
        await store.open(books)
    }

    /// What closing does (ADR 0038).
    enum CloseAction: Equatable {
        /// Close Book: save, release, show the start screen.
        case closeBook
        case quit
        /// Another window is key: it closes as usual.
        case closeWindow(NSWindow)
        case nothing
    }

    enum CloseSource {
        /// File → Close Book (⌘W), with the key window at the time.
        case menu(keyWindow: NSWindow?)
        /// The main window's red close button.
        case closeButton
    }

    /// The whole decision, from the state now and where the close came from. A press is
    /// decided when it arrives (`press`): with a book open it only closes the book, and while a
    /// close is still saving or asking, another press does nothing.
    func closeAction(from source: CloseSource) -> CloseAction {
        if case .menu(let keyWindow) = source, case .window(let other) = closeTarget(keyWindow: keyWindow) {
            return .closeWindow(other)
        }
        if closeInFlight != nil { return .nothing }
        switch store.session {
        case .open: return .closeBook
        case .closing: return .nothing
        case .choosing: break
        }
        switch (source, Self.startScreenCommandW) {
        case (.closeButton, _), (.menu, .quits): return .quit
        case (.menu, .nothing): return .nothing
        }
    }

    func perform(_ action: CloseAction) async {
        switch action {
        case .closeBook: await store.closeBook()
        case .quit: requests.send(.quit)
        case .closeWindow(let window): window.performClose(nil)
        case .nothing: break
        }
    }

    /// File → Close Book (⌘W) or the main window's close button, pressed: decided now, as the
    /// event arrives, then carried out (ADR 0038).
    @discardableResult
    func press(_ source: CloseSource) -> Task<Void, Never> {
        let action = closeAction(from: source)
        guard action == .closeBook else { return Task { await perform(action) } }
        let close = Task {
            await perform(action)
            closeInFlight = nil
        }
        closeInFlight = close
        return close
    }

    /// File a Copy can start: the book is open for editing, and not being closed.
    var canStartFiling: Bool {
        store.openBook?.isEditable == true
    }

    /// Make Editable… applies: the open book, not being closed, was repaired as it opened.
    var canMakeEditable: Bool {
        store.openBook?.canBeMadeEditable == true
    }

    /// File → Close Book's title: on the start screen it's the item ⌘W chooses there.
    var closeItemTitle: String {
        store.isChoosing ? OneBookWording.startScreenCloseMenuItem : OneBookWording.closeBookMenuItem
    }

    var isCloseItemEnabled: Bool {
        switch Self.startScreenCommandW {
        case .quits: true
        case .nothing: !store.isChoosing
        }
    }

    enum CloseTarget: Equatable {
        case mainWindow
        case window(NSWindow)
    }

    /// ⌘W acts on the main window only while it (or a sheet or child window of it) is key, or
    /// no window is; any other key window just closes.
    func closeTarget(keyWindow: NSWindow?) -> CloseTarget {
        guard let keyWindow else { return .mainWindow }
        var root = keyWindow
        while let parent = root.sheetParent ?? root.parent { root = parent }
        return root === mainWindow ? .mainWindow : .window(keyWindow)
    }

    /// The Dock icon clicked (`applicationShouldHandleReopen`): if the main window isn't on
    /// screen (minimized, or ordered out), it comes back. True if AppKit should do its own
    /// reopening, as when the main window is already visible.
    func reopenMainWindow() -> Bool {
        guard let window = mainWindow, !window.isVisible || window.isMiniaturized else { return true }
        requests.send(.bringForward(window))
        return false
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

/// What the controller asks of the whole app. Closing the start screen quits through AppKit's
/// own path (`applicationShouldTerminate`), exactly as Quit does (ADR 0038).
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
