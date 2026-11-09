import SceneItCore
import SwiftUI

/// The Scenes sheet's state while it's open: what the filter holds, and which card shows the
/// title field. Both go when the sheet closes. The ticker keeps the cards' ages current.
@MainActor
@Observable
final class ScenesSheetModel {
    var filter = ""
    /// The scene added from the sheet whose title is being typed on its card (PLAN §7.2). Its card
    /// shows whatever the filter says.
    var titling: SceneID?
    /// The scene whose card has its + tag field open: one at a time.
    var tagging: SceneID?
    @ObservationIgnored let ticker: MinuteTicker

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

    /// Esc in the sheet: closes a card's field first, keeping a title typed there (the field
    /// accepts it as it goes); the next Esc closes the sheet.
    func closeCardField() -> EscapeOutcome {
        guard titling != nil || tagging != nil else { return .passedOn }
        titling = nil
        tagging = nil
        return .handled
    }

    func close() {
        filter = ""
        titling = nil
        tagging = nil
    }
}

/// Where the sheet adds a scene (PLAN §7.2): the header's + New scene puts it after the open
/// scene, the dashed tile at the end of the story.
enum NewScenePlace {
    case afterOpenScene, atEnd
}

/// What the Scenes sheet's controls do. Adding is a step on `structureUndo` (PLAN §8.6); a card's
/// tags change through the Tags tab's own actions, on the scene's page undo (#20).
struct ScenesActions {
    let book: AppOpenBook
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
        model.titling = added
        return added
    }

    /// The title field's text, as the page's title field reads it (ADR 0015).
    func setTitle(_ typed: String, of scene: SceneID) {
        book.setTitle(of: scene, to: SceneTitle(pasted: typed))
    }

    /// The title field on `scene`'s card is done with: Return, Esc, or the focus went elsewhere.
    func finishTitling(_ scene: SceneID) {
        if model.titling == scene { model.titling = nil }
    }

    /// A card's + tag chip: opens the field on that card, closing any other.
    func startTagging(_ scene: SceneID) {
        guard book.isEditable else { return }
        model.tagging = scene
    }

    /// The card's + tag field closed: Esc, or the focus left it empty.
    func stopTagging(_ scene: SceneID) {
        if model.tagging == scene { model.tagging = nil }
    }

    func show(_ view: ScenesView) {
        preferences.showScenes(as: view)
    }
}
