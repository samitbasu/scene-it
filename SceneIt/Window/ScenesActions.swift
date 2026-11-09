import AppKit
import SceneItCore
import SwiftUI
import UniformTypeIdentifiers

/// The one field open on a card of the Scenes sheet, if any.
enum CardField: Hashable {
    /// The title of a scene just added from the sheet (PLAN §7.2). Its card shows whatever the
    /// filter says.
    case titling(SceneID)
    /// The + tag field.
    case tagging(SceneID)
}

/// The Scenes sheet's state while it's open: what the filter holds, which card has a field open,
/// which card the keys act on, and a drag under way. They go when the sheet closes. The ticker
/// keeps the cards' ages current.
@MainActor
@Observable
final class ScenesSheetModel {
    var filter = ""
    var field: CardField?
    /// The card the arrow keys, Delete and Return act on (PLAN §7.2).
    var focused: SceneID?
    /// The card or tile the last single click landed on, while nothing has moved since: the only
    /// item a double click may open (ADR 0043).
    var clicked: SceneDrag?
    var drop = SceneDropState.idle
    /// The size of the grid's cards, laid out: how many go across, for the up and down arrows.
    @ObservationIgnored var gridSize = CGSize.zero
    @ObservationIgnored let ticker: MinuteTicker
    /// The sheet's own focus, which takes the keys when no field has them.
    @ObservationIgnored let keyFocus = UndoFocusAnchor()
    /// Watches the mouse button while a drag is under way, since a drag dropped nowhere tells no
    /// drop zone it ended. The drag's own tracking takes the release, so the release is looked
    /// for while the pointer is outside every zone; a later click is the backstop.
    @ObservationIgnored private var dragEndMonitor: Any?
    @ObservationIgnored private var releaseWatch: Task<Void, Never>?
    /// How many mouse buttons are down; a test can stand in for the hardware.
    @ObservationIgnored var mouseButtonsDown: () -> Int = { NSEvent.pressedMouseButtons }

    /// The scene whose title is being typed on its card.
    var titling: SceneID? {
        if case .titling(let scene) = field { scene } else { nil }
    }

    /// The scene whose card has its + tag field open.
    var tagging: SceneID? {
        if case .tagging(let scene) = field { scene } else { nil }
    }

    init(ticker: MinuteTicker = MinuteTicker(clock: ContinuousClock())) {
        self.ticker = ticker
    }

    isolated deinit {
        stopWatchingTheDrag()
        releaseWatch?.cancel()
    }

    /// A card of the grid: a story scene and its place in the whole story, from 1.
    struct Card {
        let number: Int
        let scene: BookScene
    }

    /// The cards the grid shows of `book`'s story, in story order: those the filter matches, and
    /// the scene being titled, whatever it holds.
    func cards(of book: Book) -> [Card] {
        let filter = SceneFilter(filter)
        return book.scenes.enumerated()
            .map { Card(number: $0.offset + 1, scene: $0.element) }
            .filter { filter.matches($0.scene) || $0.scene.id == titling }
    }

    /// A card's field is done with: no view has the keys, and on the next turn, once SwiftUI has
    /// taken the field away, the sheet takes them, unless something else did meanwhile. Taking
    /// them at once leaves the field in the window.
    func returnKeys(from view: NSView?) {
        focused = nil
        view?.window?.makeFirstResponder(nil)
        DispatchQueue.main.async { [keyFocus] in
            guard let window = keyFocus.view?.window, window.firstResponder === window else { return }
            keyFocus.takeFocus()
        }
    }

    /// The grid the arrow keys move in: the cards shown, as laid out in `view`.
    func grid(of book: Book, _ view: ScenesView) -> CardGrid {
        CardGrid(
            cards: cards(of: book).map(\.scene.id),
            columns: WindowMetrics.Scenes.columns(fitting: gridSize, view))
    }

    /// Esc in the sheet: closes a card's field first, keeping a title typed there (the field
    /// accepts it as it goes), and gives the sheet the keys again; the next Esc closes the sheet.
    func closeCardField() -> KeyOutcome {
        guard field != nil else { return .passedOn }
        field = nil
        returnKeys(from: keyFocus.view)
        return .handled
    }

    /// The sheet's own focus gained or lost the keys. Losing them (to the filter, a card's field,
    /// anything) drops the card focus, so the keys never act on a card the writer has stopped
    /// looking at.
    func sheetKeys(_ change: FocusChange) {
        if change == .lost { focused = nil }
    }

    /// Forgets a card field or focus whose scene has left the story (cut, or its add undone). The
    /// cards and tiles may have moved under the pointer, so the last click is forgotten too.
    func keepToTheStory(of book: Book) {
        clicked = nil
        let story = Set(book.scenes.map(\.id))
        if let scene = titling ?? tagging, !story.contains(scene) { field = nil }
        if let focused, !story.contains(focused) { self.focused = nil }
    }

    func beginDrag(_ drag: SceneDrag) {
        drop.begin(drag)
        stopWatchingTheDrag()
        dragEndMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp, .leftMouseDown]) {
            [weak self] event in
            MainActor.assumeIsolated { self?.dragMayHaveEnded(drag) }
            return event
        }
    }

    /// The mouse button went up or down after `drag` began: a drop has happened by now, or never
    /// will. On the next turn, after any drop, a drag still under way is over.
    func dragMayHaveEnded(_ drag: SceneDrag) {
        stopWatchingTheDrag()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.drop.drag == drag else { return }
            self.drop.end()
        }
    }

    /// The pointer left `zone`. Once it's outside every zone, the drag is over as soon as no mouse
    /// button is down: it was dropped in a gap or outside the sheet.
    func exitDrop(_ zone: DropZone) {
        drop.exit(zone)
        guard drop.isOutsideEveryZone, releaseWatch == nil else { return }
        releaseWatch = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.drop.isOutsideEveryZone else { break }
                if self.mouseButtonsDown() == 0 {
                    self.drop.end()
                    break
                }
                try? await Task.sleep(for: WindowMetrics.Scenes.releaseCheck.duration)
            }
            self?.releaseWatch = nil
        }
    }

    private func stopWatchingTheDrag() {
        if let dragEndMonitor { NSEvent.removeMonitor(dragEndMonitor) }
        dragEndMonitor = nil
    }

    func close() {
        filter = ""
        field = nil
        focused = nil
        clicked = nil
        drop.end()
        stopWatchingTheDrag()
        releaseWatch?.cancel()
        releaseWatch = nil
    }
}

/// Where the sheet adds a scene (PLAN §7.2): the header's + New scene puts it after the open
/// scene, the dashed tile at the end of the story.
enum NewScenePlace {
    case afterOpenScene, atEnd
}

/// What the Scenes sheet's controls do. Adding, moving, cutting, restoring and deleting are steps
/// on `structureUndo` (PLAN §8.6); a card's tags change through the Tags tab's own actions, on
/// the scene's page undo (#20).
struct ScenesActions {
    let book: AppOpenBook
    let store: AppBookStore
    let preferences: AppPreferences
    let model: ScenesSheetModel
    let tags: TagActions
    let mode: Binding<WindowMode>

    /// The scene opens and the sheet closes.
    func open(_ scene: SceneID) {
        guard book.book.scene(scene) != nil else { return }
        book.select(scene)
        mode.wrappedValue = mode.wrappedValue.closingSheet
    }

    /// A click on a card or tile, as in the Finder: a double click opens its scene. A single click
    /// puts the card focus on a card at once, so the first click of a double click does too. The
    /// focus is the story grid's, so a single click on a Boneyard tile only records the click.
    ///
    /// A double click opens only the item its first click landed on. Its first click may have gone
    /// to a control (a tile's ↩, a chip's ×) that moved another item under the pointer; then the
    /// second click counts as a first click.
    func click(_ click: SceneClick, on item: SceneDrag) {
        if click == .double, model.clicked == item {
            open(item.scene)
            return
        }
        model.clicked = item
        if case .card(let scene) = item { select(scene) }
    }

    /// The sheet takes the keys, and they act on `scene`'s card.
    func select(_ scene: SceneID) {
        model.keyFocus.takeFocus()
        model.focused = scene
    }

    /// Adds an untitled scene, which opens, and puts the title field on its card. The sheet stays
    /// open, so the writer can outline several scenes in a row.
    @discardableResult
    func add(_ place: NewScenePlace) -> SceneID? {
        let after: SceneID? =
            switch place {
            case .afterOpenScene: book.openScene
            case .atEnd: nil
            }
        guard let added = book.addScene(after: after) else { return nil }
        model.focused = nil
        model.field = .titling(added)
        return added
    }

    /// The title field on `scene`'s card is done with: Return, Esc, or the focus went elsewhere.
    func finishTitling(_ scene: SceneID) {
        if model.field == .titling(scene) { model.field = nil }
    }

    /// A card's + tag chip: opens the field on that card, closing any other.
    func startTagging(_ scene: SceneID) {
        guard book.accepts(.manuscript) else { return }
        model.focused = nil
        model.field = .tagging(scene)
    }

    /// The card's + tag field closed: Esc, or the focus left it empty.
    func stopTagging(_ scene: SceneID) {
        if model.field == .tagging(scene) { model.field = nil }
    }

    func show(_ view: ScenesView) {
        preferences.showScenes(as: view)
    }

    // MARK: Moving, cutting and restoring (PLAN §7.2, §7.3)

    /// A Boneyard tile's ↩: the scene goes to the end of the story.
    @discardableResult
    func restoreToEnd(_ scene: SceneID) -> Bool {
        book.change(.restore(scene, to: .end))
    }

    /// The tile's Delete Permanently…: asks, then hides the scene in the book's Deleted section
    /// (ADR 0031). If it was open, no scene is. If the book closed or was read again while the
    /// writer was asked, nothing is deleted, and the writer is told.
    func deletePermanently(_ scene: SceneID) async {
        guard book.accepts(.manuscript), let shown = book.book.boneyard.first(where: { $0.id == scene })
        else { return }
        guard await store.ask(BoneyardWording.confirmDelete(shown)) == .delete else { return }
        guard store.current === book else {
            await store.tell(BoneyardWording.notDeleted(shown, .bookClosed))
            return
        }
        guard book.deleteFromBoneyard(scene) else {
            await store.tell(BoneyardWording.notDeleted(shown, .refused))
            return
        }
    }

    /// A card or tile starts to be dragged: what the drag carries, which only this app reads.
    func beginDrag(_ drag: SceneDrag) -> NSItemProvider {
        model.beginDrag(drag)
        let provider = NSItemProvider()
        let data = Data(drag.scene.rawValue.utf8)
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.sceneDrag.identifier, visibility: .ownProcess
        ) {
            $0(data, nil)
            return nil
        }
        return provider
    }

    func accepts(_ zone: DropZone) -> Bool {
        book.accepts(.manuscript) && model.drop.accepts(zone)
    }

    func enter(_ zone: DropZone) {
        model.drop.enter(zone)
    }

    func exit(_ zone: DropZone) {
        model.exitDrop(zone)
    }

    /// The drop on `zone`: the move, cut or restore it makes, if any.
    @discardableResult
    func drop(on zone: DropZone) -> Bool {
        guard book.accepts(.manuscript), let change = model.drop.drop(on: zone) else {
            model.drop.end()
            return false
        }
        return book.change(change)
    }

    // MARK: The keys (PLAN §7.2)

    /// The arrows move the focus from card to card, and with Option move the card; Delete cuts
    /// the focused card, and Return opens it. The first arrow puts the focus on a card.
    func handle(_ key: CardKey) -> KeyOutcome {
        model.clicked = nil
        let grid = model.grid(of: book.book, preferences.scenesView)
        guard let focused = model.focused, grid.cards.contains(focused) else {
            switch key {
            case .focus, .move:
                model.focused = grid.start(at: book.openScene)
                return model.focused == nil ? .passedOn : .handled
            case .cut, .open:
                return .passedOn
            }
        }
        switch key {
        case .focus(let step):
            guard let next = grid.neighbor(of: focused, step) else { return .passedOn }
            model.focused = next
        case .move(let step):
            guard let next = grid.neighbor(of: focused, step),
                let slot = book.book.slot(takingThePlaceOf: next, from: focused),
                book.change(.move(focused, to: slot))
            else { return .passedOn }
        case .cut:
            let next = grid.neighbor(of: focused, .right) ?? grid.neighbor(of: focused, .left)
            guard book.change(.cut(focused)) else { return .passedOn }
            model.focused = next
        case .open:
            open(focused)
        }
        return .handled
    }
}

/// A key the Scenes sheet's cards take.
enum CardKey: Equatable {
    /// An arrow: the focus goes to the next card that way.
    case focus(GridStep)
    /// Option and an arrow: the focused card moves that way.
    case move(GridStep)
    /// Delete or Forward Delete: the focused card is cut.
    case cut
    /// Return or Enter: the focused card's scene opens.
    case open

    /// Arrows repeat while held; Delete and Return act once per press, so holding Delete can't
    /// cut card after card.
    init?(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let step: GridStep? =
            switch event.specialKey {
            case .leftArrow?: .left
            case .rightArrow?: .right
            case .upArrow?: .up
            case .downArrow?: .down
            default: nil
            }
        switch (step, event.specialKey, modifiers) {
        case (let step?, _, []): self = .focus(step)
        case (let step?, _, [.option]): self = .move(step)
        case (nil, .delete?, []), (nil, .deleteForward?, []): self = .cut
        case (nil, .carriageReturn?, []), (nil, .enter?, []): self = .open
        default: return nil
        }
        if event.isARepeat, self == .cut || self == .open { return nil }
    }
}

/// A click on a card or tile, counted as the system counts them.
enum SceneClick: Equatable {
    case single, double

    /// Only a mouse button event has a click count; asking any other raises.
    init(_ event: NSEvent?) {
        guard let event, Self.buttonEvents.contains(event.type), event.clickCount >= 2 else {
            self = .single
            return
        }
        self = .double
    }

    private static let buttonEvents: Set<NSEvent.EventType> = [
        .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
    ]
}

extension UTType {
    static let sceneDrag = UTType(exportedAs: SceneItCore.sceneDragTypeIdentifier)
}
