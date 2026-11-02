import Foundation
import Observation

/// The one open book (ADR 0021): the in-memory `Book`, and, when it's editable, the autosave
/// driver and the writer that saves it. Views read it; every change goes through its methods,
/// which tell autosave in the same main-actor turn.
///
/// It is the driver's `AutosaveSaver`. The driver holds it weakly, so once the store lets go
/// of a book, its driver stops scheduling saves.
@MainActor
@Observable
public final class OpenBook<C: Clock<Duration>>: AutosaveSaver {
    public let layout: PackageLayout
    public private(set) var book: Book
    public private(set) var openScene: SceneID?
    /// The last save that succeeded: when, and what it did for the backups.
    public private(set) var lastSave: (at: Date, backups: SavedBackups?)?
    @ObservationIgnored public let structureUndo = UndoManager()

    private var access: Access
    @ObservationIgnored private weak var store: BookStore<C>?
    @ObservationIgnored private var ids = IDGenerator<SystemRandomNumberGenerator>.system

    private enum Access {
        case writable(AutosaveDriver<C>, BookWriter, Edits)
        case readOnly(ReadOnlyReason)
        case closed
    }

    enum Edits {
        case accepted
        /// While the store writes this book's final copy elsewhere, so nothing typed can miss it.
        case refused
    }

    init(_ opened: OpenedBook, clock: C, mirror: BackupMirror, store: BookStore<C>) {
        self.store = store
        book = opened.book
        access = .closed
        switch opened {
        case .editing(let editable):
            layout = editable.package.layout
            access = .writable(
                AutosaveDriver(clock: clock, saver: self), BookWriter(editable.package, mirror: mirror),
                .accepted)
        case .readOnly(let readOnly, let reason):
            layout = readOnly.layout
            access = .readOnly(reason)
        }
        openScene = book.scenes.first?.id
    }

    public var status: BookStatus {
        switch access {
        case .writable(let driver, _, _): BookStatus(autosave: driver.state, lastBackups: lastSave?.backups)
        case .readOnly(let reason): .readOnly(reason)
        case .closed: .closed
        }
    }

    public var isEditable: Bool {
        editingDriver != nil
    }

    var autosave: AutosaveDriver<C>? {
        if case .writable(let driver, _, _) = access { driver } else { nil }
    }

    /// The driver, while edits are accepted.
    private var editingDriver: AutosaveDriver<C>? {
        if case .writable(let driver, _, .accepted) = access { driver } else { nil }
    }

    func setEdits(_ edits: Edits) {
        if case .writable(let driver, let writer, _) = access { access = .writable(driver, writer, edits) }
    }

    // MARK: Edits

    public func setTitle(of scene: SceneID, to title: SceneTitle) {
        edit(scene) { $0.title = title }
    }

    public func replaceBody(of scene: SceneID, with body: [Paragraph]) {
        edit(scene) { $0.body = body }
    }

    public func replaceNotes(of scene: SceneID, with notes: [Paragraph]) {
        edit(scene) { $0.notes = notes }
    }

    public func showRightPanelTab(_ tab: RightPanelTab) {
        changeSettings { $0.rightPanel = tab }
    }

    public func setRightPanel(_ visibility: PanelVisibility) {
        changeSettings { $0.rightPanelOpen = visibility }
    }

    public func toggleRightPanel() {
        setRightPanel(book.settings.rightPanelOpen == .open ? .closed : .open)
    }

    /// The window's own state, so a read-only book follows it too, in memory only.
    private func changeSettings(_ change: (inout BookSettings) -> Void) {
        var settings = book.settings
        change(&settings)
        guard settings != book.settings else { return }
        switch access {
        case .writable(let driver, _, .accepted):
            book.settings = settings
            driver.send(.edited)
        case .readOnly:
            book.settings = settings
        case .writable(_, _, .refused), .closed:
            return
        }
    }

    /// Adds an untitled scene after `scene` (at the end if `nil` or not in the story) and opens it.
    @discardableResult
    public func addScene(after scene: SceneID?) -> SceneID? {
        guard let driver = editingDriver else { return nil }
        let new = BookScene(id: ids.sceneID(), modified: Timestamp(.now, in: .current), title: "")
        let index = scene.flatMap { id in book.scenes.firstIndex { $0.id == id } }.map { $0 + 1 }
        book.scenes.insert(new, at: index ?? book.scenes.endIndex)
        driver.send(.edited)
        select(new.id)
        return new.id
    }

    public func select(_ scene: SceneID?) {
        guard scene != openScene else { return }
        openScene = scene
        autosave?.send(.sceneSwitched)
    }

    private func edit(_ id: SceneID, _ change: (inout BookScene) -> Void) {
        guard let driver = editingDriver else { return }
        for list in [\Book.scenes, \Book.boneyard] {
            guard let index = book[keyPath: list].firstIndex(where: { $0.id == id }) else { continue }
            var scene = book[keyPath: list][index]
            change(&scene)
            guard scene != book[keyPath: list][index] else { return }
            scene.modified = Timestamp(.now, in: .current)
            book[keyPath: list][index] = scene
            driver.send(.edited)
            return
        }
    }

    // MARK: Saving

    public func save(_ request: SaveRequest) async throws(SaveError) {
        // Unreachable in practice: closing a book drops its driver, the only caller.
        guard case .writable(_, let writer, _) = access else {
            throw .fileSystem(FileSystemError(.write, layout.book, .notFound))
        }
        let snapshot = book
        do {
            let result = try await writer.save(snapshot, onExternalChange: request.onExternalChange)
            let backups: SavedBackups? =
                switch result {
                case .unchanged: lastSave?.backups
                case .saved(let backups): backups
                }
            let now = Date.now
            lastSave = (now, backups)
            store?.bookSaved(at: now)
        } catch {
            Log.store.error("a save failed", ["error": .error(LoggedError(error))])
            // Runs after the driver has handled this failure, so it sees the pause, if any.
            Task { [weak self] in
                guard let self, case .paused = self.autosave?.state else { return }
                await self.store?.askAboutExternalChange(in: self)
            }
            throw error
        }
    }

    /// Saves before the writer leaves the book, asking whenever that would lose edits.
    func settle(before leaving: Leaving, asking prompts: any StorePrompts) async -> Settled {
        guard let driver = autosave else { return .saved }
        while true {
            let verdict: QuitVerdict
            do {
                verdict = try await driver.prepareToQuit()
            } catch {
                return .stay
            }
            switch verdict {
            case .terminate:
                if driver.state.quitDecision == .settled(.terminate) { return .saved }
            case .askWriter(let problem):
                switch await prompts.ask(QuitWording.alert(for: problem, leaving: leaving)) {
                case .retry, .wait: continue
                case .quitAnyway: return .discarding
                case .cancel: return .stay
                }
            }
        }
    }

    enum Settled {
        /// Every edit is on disk (or the book is read-only).
        case saved
        /// The writer chose to leave without saving.
        case discarding
        case stay
    }

    func keepMyVersion() {
        autosave?.send(.externalChangeResolved)
    }

    func saveNow() {
        autosave?.send(.saveCommand)
    }

    func appDeactivated() {
        autosave?.send(.appDeactivated)
    }

    /// Closes the book at once, synchronously: from here on it refuses every edit, and its
    /// driver is dropped. The caller releases the returned writer (`BookStore.release`).
    func detach() -> BookWriter? {
        defer { access = .closed }
        if case .writable(_, let writer, _) = access { return writer } else { return nil }
    }
}
