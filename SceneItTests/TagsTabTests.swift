import AppKit
import SceneItCore
import SceneItTestSupport
import SwiftUI
import Testing

@testable import SceneIt

/// The open scene, tagged as in mockup 06, another story scene and a Boneyard scene.
private let ferry = scene("The ferry", [[Run("The ferry left at dawn, and Mara watched.")]])
private let arrival = scene("Arrival", [[Run("Nobody met her at the landing.")]])
private let brother = scene("The brother", [[Run("Tomas wrote twice.")]])

private func tagged(_ scene: BookScene, _ tags: [String]) -> BookScene {
    var scene = scene
    scene.tags = tags
    return scene
}

/// The Tags tab (#20) in the real window: the + tag field, a chip's ×, a row's toggle and ⌕, each
/// edit one step on the page's undo that the window's Undo and Redo reach, named; read-only, no
/// editing; and an edit saved to `book.md`.
///
/// SwiftUI exposes no accessibility tree offscreen, so the ×, the rows and the ⌕ are exercised
/// through the `TagActions` their buttons call, made from the window's own book, page and Search
/// sheet; the + tag field is the window's own, driven through its field editor's commands.
@Suite(.serialized, .timeLimit(.minutes(2)))
@MainActor
struct TagsTabTests {
    /// Return adds the tag and keeps the focus in the field for the next (the owner); ⌘Z there
    /// undoes the field's own typing, and on the page it undoes the tag.
    @Test func theFieldAddsATagWithoutItsHashInTheBooksSpellingAndKeepsTheFocus() async throws {
        try await withTagsTab { harness, _ in
            let scene = try #require(harness.book.openScene)
            try harness.typeTag("#SET Piece")
            #expect(harness.tags() == ["opening", "Mara", "set piece"], "the book's spelling, no #")
            let field = try harness.tagField()
            #expect(field.stringValue.isEmpty, "Return empties the field")
            #expect(harness.fieldHasTheFocus(field), "the focus stays in the field")
            #expect(harness.book.pageUndo(for: scene).undoActionName == TagWording.addUndoName)
            try await harness.expectUndoMenu(undo: nil, redo: nil)

            try harness.typeTag("  #storm ")
            #expect(harness.tags() == ["opening", "Mara", "set piece", "storm"], "a second tag in a row")
            let editor = try harness.typeInField("fo", field)
            try harness.undo.undo()
            #expect(editor.string.isEmpty, "Undo in the field takes back its typing")
            #expect(harness.tags() == ["opening", "Mara", "set piece", "storm"], "and not a tag")

            harness.focusPage(at: 0)
            try await harness.expectUndoMenu(undo: TagWording.addUndoName, redo: nil)
            try harness.undoOnThePage()
            #expect(harness.tags() == ["opening", "Mara", "set piece"])
            try await harness.expectUndoMenu(undo: TagWording.addUndoName, redo: TagWording.addUndoName)
            try harness.undoOnThePage()
            #expect(harness.tags() == ["opening", "Mara"])
            try await harness.expectUndoMenu(undo: nil, redo: TagWording.addUndoName)
            try harness.redoOnThePage()
            #expect(harness.tags() == ["opening", "Mara", "set piece"])

            // Last: a test's stand-in for an event leaves an empty undo group where nothing changed.
            try harness.typeTag("mara")
            #expect(harness.tags() == ["opening", "Mara", "set piece"], "the scene has it already")
        }
    }

    @Test func escEmptiesTheFieldAndGoesBackToThePage() async throws {
        try await withTagsTab { harness, _ in
            let field = try harness.tagField()
            let editor = try harness.typeInField("half", field)
            editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
            #expect(field.stringValue.isEmpty)
            #expect(harness.window.firstResponder === harness.page)
            #expect(harness.tags() == ["opening", "Mara"])
        }
    }

    /// A chip's × leaves the focus where it was; on the page, Undo puts the tag back in place.
    @Test func aChipsCrossRemovesTheTagAndUndoPutsItBackInPlace() async throws {
        try await withTagsTab { harness, actions in
            let scene = try #require(harness.book.openScene)
            let field = try harness.tagField()
            _ = try harness.typeInField("", field)
            try harness.asAnEvent { #expect(actions.remove("opening", from: scene)) }
            #expect(harness.tags() == ["Mara"])
            #expect(harness.fieldHasTheFocus(field), "the focus didn't move")
            harness.focusPage(at: 0)
            try await harness.expectUndoMenu(undo: TagWording.removeUndoName, redo: nil)
            try harness.undoOnThePage()
            #expect(harness.tags() == ["opening", "Mara"], "back where it was")
            try await harness.expectUndoMenu(undo: nil, redo: TagWording.removeUndoName)
            try harness.redoOnThePage()
            #expect(harness.tags() == ["Mara"])
        }
    }

    /// A row adds a tag the scene hasn't (here one only the Boneyard uses) and removes one it
    /// has, leaving the focus on the page where it was.
    @Test func aRowTogglesItsTagOnTheOpenScene() async throws {
        try await withTagsTab { harness, actions in
            let scene = try #require(harness.book.openScene)
            try #require(
                harness.book.tags.entries.contains { $0.tag == "Tomas" },
                "precondition: the Boneyard's tag is listed")
            harness.focusPage(at: 0)
            try harness.asAnEvent { #expect(actions.toggle("Tomas", on: scene)) }
            #expect(harness.tags() == ["opening", "Mara", "Tomas"])
            #expect(harness.window.firstResponder === harness.page)
            try await harness.expectUndoMenu(undo: TagWording.addUndoName, redo: nil)
            try harness.asAnEvent { #expect(actions.toggle("Mara", on: scene)) }
            #expect(harness.tags() == ["opening", "Tomas"])
            try await harness.expectUndoMenu(undo: TagWording.removeUndoName, redo: nil)

            try harness.undoOnThePage()
            #expect(harness.tags() == ["opening", "Mara", "Tomas"])
            try await harness.expectUndoMenu(undo: TagWording.addUndoName, redo: TagWording.removeUndoName)
            try harness.undoOnThePage()
            #expect(harness.tags() == ["opening", "Mara"])
            try await harness.expectUndoMenu(undo: nil, redo: TagWording.addUndoName)
            try harness.redoOnThePage()
            try harness.redoOnThePage()
            #expect(harness.tags() == ["opening", "Tomas"])
        }
    }

    /// Typing on the page before and after a tag edit are steps of their own.
    @Test func typingOnThePageAndATagEditAreSeparateSteps() async throws {
        try await withTagsTab { harness, actions in
            let scene = try #require(harness.book.openScene)
            try harness.asAnEvent {
                harness.focusPage(at: 0)
                harness.page.insertText("Then ", replacementRange: harness.page.selectedRange())
            }
            try harness.asAnEvent { #expect(actions.toggle("clue", on: scene)) }
            try harness.asAnEvent {
                harness.page.insertText("again ", replacementRange: harness.page.selectedRange())
            }
            #expect(
                harness.body(scene).first == [Run("Then again The ferry left at dawn, and Mara watched.")])
            try harness.undoOnThePage()
            #expect(harness.tags() == ["opening", "Mara", "clue"], "the typing after it goes first")
            #expect(harness.body(scene).first == [Run("Then The ferry left at dawn, and Mara watched.")])
            try harness.undoOnThePage()
            #expect(harness.tags() == ["opening", "Mara"])
            #expect(harness.body(scene).first == [Run("Then The ferry left at dawn, and Mara watched.")])
            try harness.undoOnThePage()
            #expect(harness.body(scene).first == [Run("The ferry left at dawn, and Mara watched.")])
            await eventually { harness.pageMirrorsModel }
        }
    }

    @Test func theSearchButtonOpensSearchOnTheTagInTheWholeBooksTags() async throws {
        try await withTagsTab { harness, actions in
            harness.search.scope = .thisScene
            harness.search.set(.matchCase, .on)
            actions.search("!?")
            #expect(harness.modes.mode == .page, "a tag with no word has nothing to search for")
            actions.search("set piece")
            try await harness.expectSearching(for: "\"set piece\"", finding: [arrival.id])
        }
    }

    @Test func aReadOnlyBookShowsTheTagsWithoutEditingAndStillSearches() async throws {
        try await withTagsTab(holdingTheLock: true) { harness, actions in
            let scene = try #require(harness.book.openScene)
            await eventually { harness.tagsList != nil }
            try #require(harness.tagsList != nil, "precondition: the tab's list shows")
            #expect(try harness.tagFieldIfShown() == nil, "no + tag field")
            #expect(!actions.toggle("clue", on: scene))
            #expect(!actions.remove("Mara", from: scene))
            #expect(!actions.add("storm", to: scene))
            #expect(harness.tags() == ["opening", "Mara"])
            actions.search("Tomas")
            try await harness.expectSearching(for: "Tomas", finding: [brother.id])
        }
    }

    @Test func aTagEditReachesBookMD() async throws {
        try await withTagsTab { harness, _ in
            let scene = try #require(harness.book.openScene)
            try harness.typeTag("red, door")
            await eventually { harness.book.status == .saved }
            #expect(try bookOnDisk(harness.url).scene(scene)?.tags == ["opening", "Mara", "red, door"])
            #expect(try bookOnDisk(harness.url) == harness.book.book)
        }
    }
}

/// The Tags tab's book (see the top of this file) in the window, the tab showing, with the
/// `TagActions` the tab's buttons call.
private func withTagsTab(
    holdingTheLock: Bool = false, _ body: (PageHarness, TagActions) async throws -> Void
) async throws {
    let scenes = [
        tagged(ferry, ["opening", "Mara"]), tagged(arrival, ["Mara", "set piece", "clue"]),
    ]
    try await withPage(
        scenes, boneyard: [tagged(brother, ["Tomas", "clue"])], holdingTheLock: holdingTheLock
    ) {
        harness in
        let (panel, tab) = (harness.preferences.rightPanel, harness.preferences.rightPanelTab)
        defer {
            harness.preferences.setRightPanel(panel)
            harness.preferences.showRightPanelTab(tab)
        }
        harness.preferences.reveal(.tags)
        try #require(harness.book.openScene == ferry.id, "precondition: the ferry is open")
        await eventually { harness.tagsList != nil }
        try #require(harness.tagsList != nil, "precondition: the tab shows")
        let modes = harness.modes
        let actions = TagActions(
            book: harness.book, page: harness.page, search: harness.search,
            mode: Binding(get: { modes.mode }, set: { modes.mode = $0 }))
        try await body(harness, actions)
    }
}

extension PageHarness {
    /// The open scene's tags.
    fileprivate func tags() -> [String] {
        book.book.scene(book.openScene)?.tags ?? []
    }

    fileprivate func tagFieldIfShown() throws -> AdmittingTextField? {
        subviewTree(of: window.contentView).compactMap { $0 as? AdmittingTextField }.first {
            $0.placeholderString == TagWording.addPlaceholder
        }
    }

    fileprivate func fieldHasTheFocus(_ field: AdmittingTextField) -> Bool {
        field.currentEditor() != nil && window.firstResponder === field.currentEditor()
    }

    fileprivate func tagField() throws -> AdmittingTextField {
        try #require(try tagFieldIfShown(), "precondition: the + tag field shows")
    }

    /// The tab's list of the book's tags: SwiftUI's scroll view, in the panel.
    fileprivate var tagsList: NSScrollView? {
        subviewTree(of: window.contentView).compactMap { $0 as? NSScrollView }.first {
            !($0 is DeskView)
                && $0.convert($0.bounds, to: nil).minX >= window.frame.width - WindowMetrics.panelWidth - 1
        }
    }

    /// Types `text` into the + tag field through its field editor, as the keyboard would.
    fileprivate func typeInField(_ text: String, _ field: AdmittingTextField) throws -> NSTextView {
        #expect(window.makeFirstResponder(field))
        let editor = try #require(field.currentEditor() as? NSTextView, "precondition: the field is editing")
        editor.insertText(text, replacementRange: editor.selectedRange())
        return editor
    }

    /// Types `text` into the + tag field, then Return.
    fileprivate func typeTag(_ text: String) throws {
        let editor = try typeInField(text, try tagField())
        try asAnEvent { editor.doCommand(by: #selector(NSResponder.insertNewline(_:))) }
    }

    /// Runs `body` as one event would, as far as the open scene's page undo is concerned: a
    /// test has no events, so without this everything it does lands in one undo group.
    fileprivate func asAnEvent(_ body: () throws -> Void) throws {
        let undo = book.pageUndo(for: try #require(book.openScene))
        try asSeparateEvents(undo) { try anEvent(undo, body) }
    }

    /// The window's Undo and Redo (the toolbar's and the Edit menu's) read "Undo `undo`" and
    /// "Redo `redo`", or are off where `nil`.
    fileprivate func expectUndoMenu(undo: String?, redo: String?) async throws {
        let router = try self.undo
        let wanted = UndoState(undo: undo.map { "Undo \($0)" }, redo: redo.map { "Redo \($0)" })
        await eventually { router.state == wanted }
        #expect(router.state == wanted)
    }

    /// The Search sheet is open on `text`, ticked to search tags alone, in the whole book; its
    /// search finds the tags of exactly `scenes`.
    fileprivate func expectSearching(for text: String, finding scenes: [SceneID]) async throws {
        #expect(modes.mode == .search)
        #expect(search.text == text)
        #expect(search.options == [.searchTags], "Search tags ticked, nothing else")
        #expect(search.scope == .wholeBook)
        await eventually { search.reported?.query == search.query }
        await search.settle()
        let update = try #require(search.reported?.update)
        let tagged = update.scenes.flatMap(\.hits).filter { $0.unit.field == .tags }.map(\.unit.scene)
        #expect(tagged == scenes)
        modes.mode = .page
    }
}
