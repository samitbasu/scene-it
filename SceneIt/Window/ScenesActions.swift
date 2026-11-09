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
    var drop = SceneDropState()
    /// The size of the grid's cards, laid out: how many go across, for the up and down arrows.
    @ObservationIgnored var gridSize = CGSize.zero
    @ObservationIgnored let ticker: MinuteTicker
    /// The sheet's own focus, which takes the keys when no field has them.
    @ObservationIgnored let keyFocus = UndoFocusAnchor()

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
    func closeCardField() -> EscapeOutcome {
        guard field != nil else { return .passedOn }
        field = nil
        returnKeys(from: keyFocus.view)
        return .handled
    }

    func close() {
        filter = ""
        field = nil
        focused = nil
        drop.end()
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

    /// A click on a card: the scene opens and the sheet closes.
    func open(_ scene: SceneID) {
        guard book.book.scene(scene) != nil else { return }
        book.select(scene)
        mode.wrappedValue = mode.wrappedValue.closingSheet
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
        model.field = .titling(added)
        return added
    }

    /// The title field on `scene`'s card is done with: Return, Esc, or the focus went elsewhere.
    func finishTitling(_ scene: SceneID) {
        if model.field == .titling(scene) { model.field = nil }
    }

    /// A card's + tag chip: opens the field on that card, closing any other.
    func startTagging(_ scene: SceneID) {
        guard book.isEditable else { return }
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
    /// (ADR 0031). If it was open, no scene is.
    func deletePermanently(_ scene: SceneID) async {
        guard book.isEditable, let shown = book.book.boneyard.first(where: { $0.id == scene }) else { return }
        guard await store.ask(BoneyardWording.confirmDelete(shown)) == .delete else { return }
        book.deleteFromBoneyard(scene)
    }

    /// A card or tile starts to be dragged: what the drag carries, which only this app reads.
    func beginDrag(_ drag: SceneDrag) -> NSItemProvider {
        model.drop.begin(drag)
        let id =
            switch drag {
            case .card(let scene), .tile(let scene): scene
            }
        let provider = NSItemProvider()
        let data = Data(id.rawValue.utf8)
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.sceneDrag.identifier, visibility: .ownProcess
        ) {
            $0(data, nil)
            return nil
        }
        return provider
    }

    func accepts(_ zone: DropZone) -> Bool {
        book.isEditable && model.drop.accepts(zone)
    }

    func enter(_ zone: DropZone) {
        model.drop.enter(zone)
    }

    func exit(_ zone: DropZone) {
        model.drop.exit(zone)
    }

    /// The drop on `zone`: the move, cut or restore it makes, if any.
    @discardableResult
    func drop(on zone: DropZone) -> Bool {
        guard book.isEditable, let change = model.drop.drop(on: zone) else {
            model.drop.end()
            return false
        }
        return book.change(change)
    }

    // MARK: The keys (PLAN §7.2)

    /// The arrows move the focus from card to card, and with Option move the card; Delete cuts
    /// the focused card, and Return opens it. The first arrow puts the focus on a card.
    func handle(_ key: CardKey) -> KeyOutcome {
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
    }
}

extension UTType {
    static let sceneDrag = UTType(exportedAs: SceneItCore.sceneDragTypeIdentifier)
}
