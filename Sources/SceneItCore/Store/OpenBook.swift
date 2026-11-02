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
        case editing(AutosaveDriver<C>, BookWriter)
        case readOnly(ReadOnlyReason)
        case closed
    }

    init(_ opened: OpenedBook, clock: C, mirror: BackupMirror, store: BookStore<C>) {
        self.store = store
        book = opened.book
        access = .closed
        switch opened {
        case .editing(let editable):
            layout = editable.package.layout
            access = .editing(
                AutosaveDriver(clock: clock, saver: self), BookWriter(editable.package, mirror: mirror))
        case .readOnly(let readOnly, let reason):
            layout = readOnly.layout
            access = .readOnly(reason)
        }
        openScene = book.scenes.first?.id
    }

    public var status: BookStatus {
        switch access {
        case .editing(let driver, _): BookStatus(autosave: driver.state, lastBackups: lastSave?.backups)
        case .readOnly(let reason): .readOnly(reason)
        case .closed: .closed
        }
    }

    public var isEditable: Bool {
        if case .editing = access { true } else { false }
    }

    var autosave: AutosaveDriver<C>? {
        if case .editing(let driver, _) = access { driver } else { nil }
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

    /// Adds an untitled scene after `scene` (at the end if `nil` or not in the story) and opens it.
    @discardableResult
    public func addScene(after scene: SceneID?) -> SceneID? {
        guard let driver = autosave else { return nil }
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
        guard let driver = autosave else { return }
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
        guard case .editing(_, let writer) = access else {
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
            lastSave = (.now, backups)
            store?.bookSaved(at: .now)
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

    /// Drops the driver and releases the package, off the main actor, once any running save ends.
    func close() async {
        let writer = detach()
        await writer?.release()
    }

    /// For termination: releases the package now unless a save is still running.
    func closeImmediately() {
        detach()?.releaseUnlessSaving()
    }

    private func detach() -> BookWriter? {
        defer { access = .closed }
        if case .editing(_, let writer) = access { return writer } else { return nil }
    }
}
