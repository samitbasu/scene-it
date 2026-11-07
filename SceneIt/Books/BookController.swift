import AppKit
import SceneItCore

typealias AppBookStore = BookStore<ContinuousClock>

/// The app's side of the `BookStore`: the panels for New and Open, books AppKit asks us to
/// open, closing the book or the window, and the store built for this kind of process. There
/// is one per process, as there is one main window (ADR 0038).
final class BookController {
    static let shared = BookController(role: .current)

    let store: AppBookStore
    /// What a press (or Quit) started and hasn't finished. Any close press meanwhile does
    /// nothing, even one decided before the store reached `closing` (while another operation
    /// held it), or before AppKit's quit got to `applicationShouldTerminate`.
    private var inFlight: InFlight?

    private enum InFlight {
        case closingBook
        case quitting
    }
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

    /// What a close press does (ADR 0038).
    enum CloseAction: Equatable {
        /// Close Book: save, release, show the start screen.
        case closeBook
        /// Quit, through AppKit's own path (`settleQuit`), which saves first.
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

    /// The whole decision, from the state now and where the press came from. The red button
    /// quits (#130); ⌘W closes the book, or quits from the start screen. While a close or a quit
    /// is under way, another press does nothing.
    func closeAction(from source: CloseSource) -> CloseAction {
        if case .menu(let keyWindow) = source, case .window(let other) = closeTarget(keyWindow: keyWindow) {
            return .closeWindow(other)
        }
        if inFlight != nil { return .nothing }
        switch (source, store.session) {
        case (_, .closing): return .nothing
        case (.closeButton, _), (.menu, .choosing): return .quit
        case (.menu, .open): return .closeBook
        }
    }

    /// File → Close Book (⌘W) or the main window's close button, pressed: decided now, as the
    /// event arrives (ADR 0038). A quit is only requested here; AppKit starts it from a run-loop
    /// source (`AppRequests`), never inside a task or a store operation.
    @discardableResult
    func press(_ source: CloseSource) -> Task<Void, Never> {
        switch closeAction(from: source) {
        case .closeBook:
            inFlight = .closingBook
            return Task {
                await store.closeBook()
                inFlight = nil
            }
        case .quit:
            inFlight = .quitting
            requests.send(.quit)
        case .closeWindow(let window):
            window.performClose(nil)
        case .nothing:
            break
        }
        return Task {}
    }

    /// The quit path's own work, for `applicationShouldTerminate`: saves and releases the book,
    /// asking (Retry / Cancel / Quit Anyway) when that can't finish. Presses do nothing until it
    /// ends; if the writer cancels, the next press is decided afresh.
    func settleQuit() async -> AppBookStore.LeaveOutcome {
        inFlight = .quitting
        defer { inFlight = nil }
        return await store.prepareToQuit()
    }

    /// File a Copy can start: the book is open for editing, and not being closed.
    var canStartFiling: Bool {
        store.openBook?.isEditable == true
    }

    /// Make Editable… applies: the open book, not being closed, was repaired as it opened.
    var canMakeEditable: Bool {
        store.openBook?.canBeMadeEditable == true
    }

    /// File → Close Book's title: on the start screen, where it quits, it says so.
    var closeItemTitle: String {
        store.isChoosing ? OneBookWording.startScreenCloseMenuItem : OneBookWording.closeBookMenuItem
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

/// What the controller asks of the whole app. The main window's close button (and ⌘W on the
/// start screen) quits through AppKit's own path (`applicationShouldTerminate`), exactly as Quit
/// does (ADR 0038).
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
