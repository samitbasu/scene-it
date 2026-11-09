import AppKit
import SceneItCore

typealias AppBookStore = BookStore<ContinuousClock>

/// The app's side of the `BookStore`: the panels for New and Open, books AppKit asks us to
/// open, closing the book or the window, and the store built for this kind of process. There
/// is one per process, as there is one main window (ADR 0038).
final class BookController {
    static let shared = BookController(role: .current)

    let store: AppBookStore
    /// The main window's focus mode and toolbar, for the View menu.
    let mainWindowChrome = MainWindowChrome()
    /// The Close Book and the quit a press (or Quit) started and that haven't finished, tracked
    /// apart so neither can clear the other's. While the book is still open, a close under way
    /// makes a close press do nothing, even one decided before the store reached `closing`
    /// (while another operation held it); a quit under way does so everywhere, even before
    /// AppKit's quit got to `applicationShouldTerminate`. Each is cleared only by its own owner,
    /// matched by identity.
    private var closeUnderWay: CloseAttempt?
    /// Also covers the time between a press and `applicationShouldTerminate`, which the app
    /// delegate's own `quitting` phase (its guard against a second `terminate`) doesn't see.
    private var quitUnderWay: QuitAttempt?
    /// When ⌘W last closed a filed copy. A press soon after, a held ⌘W repeating or a quick second
    /// press, doesn't go on to close the book (ADR 0038's guard against key repeats).
    private var copyClosed: ContinuousClock.Instant?
    /// The time now; a test can stand in for the clock.
    var now: () -> ContinuousClock.Instant = { ContinuousClock.now }
    static let closeCopyGrace = Interval(clamping: .milliseconds(700))

    private final class CloseAttempt {
        /// Its own task, which a quit pressed while it's still releasing the book waits for.
        var task: Task<Void, Never>?
    }

    private final class QuitAttempt {}

    /// A quit has been asked for and its path hasn't ended.
    var isQuitUnderWay: Bool {
        quitUnderWay != nil
    }

    /// A Close Book a press started hasn't finished: it may still be releasing the book after
    /// the start screen shows.
    var isCloseUnderWay: Bool {
        closeUnderWay != nil
    }
    let memory: any BookMemory
    /// The window's layout (ADR 0022).
    let preferences: AppPreferences
    /// The open book's page, for the Format menu and the control bar.
    let formatting: EditorFormatting
    /// The page's read aloud: the Mac's voice in the app, a silent recorder in the test host
    /// and previews.
    let readAloud: ReadAloud
    let mirror: BackupMirror
    /// Where reviews keep their backups, kept originals and locks (review format §9 Q9).
    let reviews: ReviewsFolder
    /// Where Export as SceneIt… writes: the save panel in the app; in the test host and previews
    /// nowhere, unless a test names a file.
    var exportDestination: SaveDestination
    /// Where Save Review… writes, as `exportDestination`.
    var reviewDestination: SaveDestination
    /// Where Export to Word… writes, as `exportDestination`.
    var wordDestination: WordDestination
    /// Where New Book from This Copy… makes the book, as `exportDestination`.
    var newBookDestination: SaveDestination
    /// Where Copy Review puts the review: the general pasteboard in the app; in the test host
    /// and previews a private one, so a test never replaces what the owner copied.
    let reviewPasteboard: NSPasteboard
    let prompts: any StorePrompts
    let requests: AppRequests
    /// The test host's and previews' record of `requests`; nil in the app.
    let recorded: RecordedRequests?
    private let role: ProcessRole

    /// `prompts` replaces the role's own, for a test that answers from a script.
    /// `recordedTerminate` is, in the test host, what the recorded `terminate` does: by default
    /// it leaves the quit to the test; `.over` plays a `terminate` that returned without the quit
    /// path having run.
    init(
        role: ProcessRole, prompts: (any StorePrompts)? = nil,
        recordedTerminate: AppRequests.CarriedOut = .leftToTheTest
    ) {
        self.role = role
        let standard: any StorePrompts
        let storage: any PreferenceStorage
        (memory, mirror, reviews, standard, storage, recorded) = Self.surroundings(for: role)
        recorded?.terminate = recordedTerminate
        requests = AppRequests(carryOut: recorded.map { recorder in recorder.record } ?? AppRequests.appKit)
        preferences = AppPreferences(storage)
        formatting = EditorFormatting(preferences: preferences)
        readAloud = ReadAloud(
            preferences: preferences, speech: role == .app ? SystemSpeech() : RecordedSpeech())
        self.prompts = prompts ?? standard
        exportDestination = role == .app ? .exportPanel : .nowhere
        reviewDestination = role == .app ? .reviewPanel : .nowhere
        wordDestination = role == .app ? .panel : .nowhere
        newBookDestination = role == .app ? .newBookPanel : .nowhere
        reviewPasteboard = role == .app ? .general : .withUniqueName()
        store = BookStore(
            clock: ContinuousClock(), mirror: mirror, reviews: reviews, memory: memory, prompts: self.prompts)
        recorded?.storeIsBusy = { [store] in store.isBusy }
    }

    /// The writer's own defaults, backup mirror and alerts for the app. The test host and
    /// previews get throwaway ones that never touch the writer's files, never put up a modal
    /// alert nobody can answer, and never quit the process they run in.
    private static func surroundings(for role: ProcessRole) -> (
        any BookMemory, BackupMirror, ReviewsFolder, any StorePrompts, any PreferenceStorage,
        RecordedRequests?
    ) {
        switch role {
        case .app:
            (
                DefaultsBookMemory(.standard), .standard, .standard, AlertPrompts(),
                DefaultsPreferenceStorage(.standard), nil
            )
        case .testHost, .preview:
            (
                TransientBookMemory(),
                BackupMirror(
                    root: FileManager.default.temporaryDirectory.appending(path: "Scene It Test Mirror")),
                ReviewsFolder(
                    root: FileManager.default.temporaryDirectory.appending(path: "Scene It Test Reviews")),
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
        requests.bringForward(mainWindow)
        await store.open(books)
    }

    /// What a close press does (ADR 0038).
    enum CloseAction: Equatable {
        /// Close Book: save, release, show the start screen.
        case closeBook
        /// A filed copy shows over the book: it closes, as its banner's Close does.
        case closeCopy
        /// Quit, through AppKit's own path (`settleQuit`), which saves first.
        case quit
        /// Another window is key: it closes as usual.
        case closeWindow(NSWindow)
        case nothing
    }

    enum CloseSource {
        /// File → Close Book (⌘W), with the key window at the time, and whether it's a held ⌘W
        /// repeating.
        case menu(keyWindow: NSWindow?, press: MenuPress = .first)
        /// The main window's red close button.
        case closeButton
    }

    /// The whole decision, from the state now and where the press came from. The red button
    /// quits (#130); ⌘W closes the book, or quits from the start screen. While a quit is under
    /// way, or a close while the book is still shown, another press does nothing. Once the start
    /// screen shows, a press is decided as there, even while the close is still releasing the
    /// book: `press` then asks for the quit once the close has ended (which, after Close Anyway,
    /// can be before the release has).
    func closeAction(from source: CloseSource) -> CloseAction {
        if case .menu(let keyWindow, _) = source, case .window(let other) = closeTarget(keyWindow: keyWindow)
        {
            return .closeWindow(other)
        }
        if quitUnderWay != nil { return .nothing }
        switch (source, store.session) {
        case (_, .closing): return .nothing
        case (_, .open) where closeUnderWay != nil, (_, .viewingCopy) where closeUnderWay != nil:
            return .nothing
        case (.closeButton, _), (.menu, .choosing): return .quit
        case (.menu(_, let press), .open) where copyClosed != nil && (press == .repeated || copyJustClosed):
            return .nothing
        case (.menu, .open): return .closeBook
        case (.menu, .viewingCopy): return .closeCopy
        }
    }

    /// File → Close Book (⌘W) or the main window's close button, pressed: decided now, as the
    /// event arrives (ADR 0038). A quit is only requested here; AppKit starts it from a run-loop
    /// source (`AppRequests`), never inside a task or a store operation. A quit pressed while a
    /// close is still releasing the book is requested once that close has ended, so the store
    /// is idle when AppKit's quit starts (`BookStore.isBusy`), unless Quit's own path has
    /// started meanwhile, which ends the press's quit. After Close Anyway, though, the close
    /// ends before the release does (it waits behind a save that may be stuck), and the lock
    /// may then go only with the process. Returns what there is to wait for: the close, or a
    /// quit waiting for one.
    @discardableResult
    func press(_ source: CloseSource) -> Task<Void, Never>? {
        let action = closeAction(from: source)
        // Each ⌘W swallowed after a copy closed starts the grace again, so a held ⌘W never runs on.
        if action == .nothing, case .open = store.session, copyClosed != nil { copyClosed = now() }
        switch action {
        case .closeBook:
            copyClosed = nil
            let attempt = CloseAttempt()
            closeUnderWay = attempt
            let task = Task {
                await store.closeBook()
                if closeUnderWay === attempt { closeUnderWay = nil }
            }
            attempt.task = task
            return task
        case .quit:
            let attempt = QuitAttempt()
            quitUnderWay = attempt
            guard let releasing = closeUnderWay?.task else {
                requestQuit(attempt)
                return nil
            }
            return Task {
                await releasing.value
                if quitUnderWay === attempt { requestQuit(attempt) }
            }
        case .closeCopy:
            store.closeFiledCopy()
            copyClosed = now()
        case .closeWindow(let window):
            window.performClose(nil)
        case .nothing:
            break
        }
        return nil
    }

    private func requestQuit(_ attempt: QuitAttempt) {
        requests.quit { [weak self] in
            if self?.quitUnderWay === attempt { self?.quitUnderWay = nil }
        }
    }

    /// The quit path's own work, for `applicationShouldTerminate`, whether a press or Quit
    /// started it: saves and releases the book, asking (Retry / Cancel / Quit Anyway) when that
    /// can't finish. Presses do nothing until it ends. Then the quit is over either way: a quit a
    /// click queued before `applicationShouldTerminate` ran, and AppKit hadn't started, is
    /// dropped, and after Cancel the next press is decided afresh. Its attempt is its own, so a
    /// press's backstop can never end it.
    func settleQuit() async -> AppBookStore.LeaveOutcome {
        let attempt = QuitAttempt()
        quitUnderWay = attempt
        defer {
            if quitUnderWay === attempt { quitUnderWay = nil }
            requests.dropPendingQuit()
        }
        return await store.prepareToQuit()
    }

    /// File → Close Book's title: on the start screen, where it quits, it says so.
    var closeItemTitle: String {
        if store.isChoosing { return OneBookWording.startScreenCloseMenuItem }
        if case .viewingCopy = store.session { return OneBookWording.closeCopyMenuItem }
        return OneBookWording.closeBookMenuItem
    }

    private var copyJustClosed: Bool {
        copyClosed.map { now() - $0 < Self.closeCopyGrace.duration } ?? false
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
        requests.bringForward(window)
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

    /// Review Book… (ADR 0029): a review copy, or its review file, chosen in an open panel.
    func reviewBook() async {
        guard store.isChoosing else { return }
        let panel = NSOpenPanel()
        panel.title = ReviewWording.panelTitle
        panel.prompt = ReviewWording.panelPrompt
        panel.message = ReviewWording.panelMessage
        panel.allowedContentTypes = [.reviewCopy]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        await store.openReview(url)
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
    private let carryOut: (AppRequest) -> CarriedOut
    /// The one quit asked for and not yet carried out, with what to run once it's over.
    private var pendingQuit: (() -> Void)?

    /// Whether a request is over once `carryOut` returns. AppKit's `terminate` returns only when
    /// the quit was refused (the writer's Cancel) or never asked of `applicationShouldTerminate`;
    /// when the quit goes through, it never returns. The test host's recorder returns at once,
    /// and the test plays the quit path itself.
    enum CarriedOut {
        case over
        case leftToTheTest
    }

    init(carryOut: @escaping (AppRequest) -> CarriedOut) {
        self.carryOut = carryOut
    }

    /// Brings the app forward, with `window` if there is one.
    func bringForward(_ window: NSWindow?) {
        _ = carryOut(.bringForward(window))
    }

    /// Asks AppKit to quit from a run-loop source; `whenOver` runs once `terminate` has
    /// returned, as a backstop for a quit that never reached `applicationShouldTerminate`. It
    /// also runs, harmlessly, after every Cancel: by then the quit path has ended the quit.
    func quit(whenOver: @escaping () -> Void) {
        dropPendingQuit()
        pendingQuit = whenOver
        perform(#selector(quitNow), with: nil, afterDelay: 0)
    }

    /// Drops a quit that's still waiting for its run-loop source.
    func dropPendingQuit() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(quitNow), object: nil)
        pendingQuit = nil
    }

    @objc private func quitNow() {
        let whenOver = pendingQuit
        pendingQuit = nil
        if carryOut(.quit) == .over { whenOver?() }
    }

    static func appKit(_ request: AppRequest) -> CarriedOut {
        switch request {
        case .quit:
            NSApp.terminate(nil)
        case .bringForward(let window):
            NSApp.activate()
            if let window {
                if window.isMiniaturized { window.deminiaturize(nil) }
                window.makeKeyAndOrderFront(nil)
            }
        }
        return .over
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
    /// What a recorded `terminate` does once it returns.
    var terminate = AppRequests.CarriedOut.leftToTheTest

    func record(_ request: AppRequest) -> AppRequests.CarriedOut {
        carried.append(Carried(request: request, storeWasBusy: storeIsBusy()))
        return terminate
    }

    /// The requests so far, which are then forgotten.
    func take() -> [Carried] {
        defer { carried = [] }
        return carried
    }
}

// MARK: View → Previous Scene and Next Scene

extension BookController {
    /// The scene Previous Scene or Next Scene opens, in what the window shows: a filed copy while
    /// one shows over the book, never the book hidden under it.
    func scene(_ step: SceneStep) -> SceneID? {
        store.shown.flatMap { $0.book.scene(step, from: $0.openScene) }
    }

    /// Opens that scene; `false` if there's none.
    @discardableResult
    func take(_ step: SceneStep) -> Bool {
        guard let book = store.shown, let scene = scene(step) else { return false }
        book.select(scene)
        return true
    }
}

/// Whether a ⌘W is pressed afresh or is a held key repeating.
enum MenuPress: Equatable {
    case first, repeated

    /// Only a key event can be a repeat; asking any other raises.
    init(_ event: NSEvent?) {
        guard let event, event.type == .keyDown, event.isARepeat else {
            self = .first
            return
        }
        self = .repeated
    }
}
