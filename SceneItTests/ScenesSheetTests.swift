import AppKit
import SceneItCore
import SceneItTestSupport
import SwiftUI
import Testing

@testable import SceneIt

private let ferry = scene("The ferry", [[Run("The ferry left at dawn. Mara watched.")]])
private let arrival = scene("Arrival", [[Run("Nobody met her at the landing.")]])
private let letter = scene("The letter", [[Run("He read it twice.")]])

extension OneAtATime {
    /// The Scenes sheet (#28) in the real window: opened from the View menu; both ways of adding a
    /// scene, each one step on `structureUndo` that the window's Undo reaches, with the title typed on
    /// the new card; + tag on a card, through the Tags tab's actions and undo; the filter; a card's
    /// clicks; the ages refreshing; and a read-only book.
    ///
    /// SwiftUI exposes no accessibility tree offscreen, so the cards, the tile and the chips are
    /// exercised through the `ScenesActions` their buttons call, made from the window's own book and
    /// sheet model; the title, + tag and filter fields are the window's own, driven through their
    /// field editors.
    @Suite(.serialized, .timeLimit(.minutes(2)))
    @MainActor
    struct ScenesSheetTests {
        @Test func theHeadersNewSceneAddsAfterTheOpenSceneAndTheTitleIsTypedOnItsCard() async throws {
            try await withScenesSheet { harness, actions in
                let added = try #require(actions.add(.afterOpenScene))
                #expect(harness.book.book.scenes.map(\.id) == [ferry.id, added, arrival.id, letter.id])
                #expect(harness.modes.mode == .scenes, "the sheet stays open")
                #expect(harness.scenes.titling == added)

                let editor = try await harness.titleEditor()
                editor.insertText("The crossing", replacementRange: editor.selectedRange())
                editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
                #expect(harness.book.book.scene(added)?.title == "The crossing")
                #expect(harness.scenes.titling == nil, "Return accepts the title")
                await eventually { harness.titleField == nil }

                try await harness.expectUndoMenu(undo: ScenesWording.newSceneUndoName, redo: nil)
                try harness.undo.undo()
                #expect(harness.book.book.scenes.map(\.id) == [ferry.id, arrival.id, letter.id])
                #expect(harness.book.openScene == ferry.id, "the scene that was open opens again")
                #expect(harness.book.book.scene(added) == nil)
                await eventually { harness.book.status == .saved }
                let saved = String(
                    decoding: try Data(contentsOf: harness.url.appending(path: "book.md")), as: UTF8.self)
                #expect(
                    !saved.contains("The crossing"), "a scene with only a title is blank: it goes (ADR 0041)")
                try await harness.expectUndoMenu(undo: nil, redo: ScenesWording.newSceneUndoName)
                try harness.undo.redo()
                #expect(harness.book.book.scenes.map(\.id) == [ferry.id, added, arrival.id, letter.id])
                #expect(harness.book.book.scene(added)?.title == "The crossing")
            }
        }

        /// The dashed tile, twice in a row as when outlining: each scene at the end, each one undo.
        @Test func theTileAddsAtTheEndAndEachAddIsOneUndo() async throws {
            try await withScenesSheet { harness, actions in
                // A test has no events, so each click is made one for the structure's undo.
                let structure = harness.book.structureUndo
                structure.groupsByEvent = false
                defer { structure.groupsByEvent = true }
                let first = try #require(anEventReturning(structure) { actions.add(.atEnd) })
                try await harness.acceptTitle("Fog")
                let second = try #require(anEventReturning(structure) { actions.add(.atEnd) })
                try await harness.acceptTitle("Salt")
                #expect(
                    harness.book.book.scenes.map(\.id) == [ferry.id, arrival.id, letter.id, first, second])
                #expect(harness.book.book.scenes.suffix(2).map(\.title) == ["Fog", "Salt"])
                #expect(harness.modes.mode == .scenes)

                try harness.undo.undo()
                #expect(harness.book.book.scenes.map(\.id) == [ferry.id, arrival.id, letter.id, first])
                try harness.undo.undo()
                #expect(harness.book.book.scenes.map(\.id) == [ferry.id, arrival.id, letter.id])
                await eventually { harness.book.status == .saved }
                #expect(try bookOnDisk(harness.url).scenes.map(\.id) == [ferry.id, arrival.id, letter.id])
            }
        }

        /// Trust: a title typed on a new card is in the book as it's typed, so closing the book
        /// without Return saves it.
        @Test func aTitleTypedOnACardIsSavedWhenTheBookClosesWithoutReturn() async throws {
            try await withScenesSheet { harness, actions in
                let added = try #require(actions.add(.atEnd))
                let editor = try await harness.titleEditor()
                editor.insertText("The keeper", replacementRange: editor.selectedRange())
                #expect(harness.book.book.scene(added)?.title == "The keeper", "written as it's typed")
                try #require(harness.titleField?.currentEditor() != nil, "precondition: still typing")
                #expect(await harness.store.closeBook() == .left)
                let saved = String(
                    decoding: try Data(contentsOf: harness.url.appending(path: "book.md")), as: UTF8.self)
                #expect(saved.contains("## The keeper\n"))
            }
        }

        /// Undo in the new card's title field is the scene's own title history, as on the page.
        @Test func undoInTheCardsTitleFieldIsTheScenesTitleHistory() async throws {
            try await withScenesSheet { harness, actions in
                let added = try #require(actions.add(.atEnd))
                let editor = try await harness.titleEditor()
                #expect(editor.undoManager === harness.book.titleUndo(for: added))
                editor.insertText("Fog", replacementRange: editor.selectedRange())
                try harness.undo.undo()
                #expect(harness.book.book.scene(added)?.title == "", "undone in the field, and in the book")
                try harness.undo.redo()
                #expect(harness.book.book.scene(added)?.title == "Fog")
                editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
                #expect(!harness.book.titleUndo(for: added).canUndo, "the field's steps go with it")
            }
        }

        /// Esc with a title being typed: the first closes the field, keeping the title; the second
        /// closes the sheet.
        @Test func escClosesTheTitleFieldKeepingItsTitleThenTheSheet() async throws {
            try await withScenesSheet { harness, actions in
                let added = try #require(actions.add(.afterOpenScene))
                let editor = try await harness.titleEditor()
                editor.insertText("Market day", replacementRange: editor.selectedRange())
                try press(.escape, in: harness.window)
                await eventually { harness.titleField == nil }
                #expect(harness.book.book.scene(added)?.title == "Market day")
                #expect(harness.modes.mode == .scenes)
                try press(.escape, in: harness.window)
                await eventually { harness.modes.mode == .page }
            }
        }

        /// A title typed but not accepted with Return is kept when the sheet closes.
        @Test func closingTheSheetKeepsATitleBeingTyped() async throws {
            try await withScenesSheet { harness, actions in
                let added = try #require(actions.add(.atEnd))
                let editor = try await harness.titleEditor()
                editor.insertText("Half a title", replacementRange: editor.selectedRange())
                harness.modes.mode = .page
                await eventually { harness.titleField == nil }
                #expect(harness.book.book.scene(added)?.title == "Half a title")
                #expect(harness.scenes.titling == nil)
            }
        }

        /// The title field and + tag undo their own typing while they have the focus; elsewhere in
        /// the sheet, Undo is the structure's.
        @Test func aFieldInTheSheetUndoesItsOwnTypingAndTheSheetUndoesTheStructure() async throws {
            try await withScenesSheet { harness, actions in
                _ = try #require(actions.add(.atEnd))
                let editor = try await harness.titleEditor()
                let router = try harness.undo
                await eventually { router.stack == .focusedText }
                #expect(router.manager === editor.undoManager)
                #expect(router.manager !== harness.book.structureUndo)
                editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
                await eventually { router.stack == .structure }
                #expect(router.manager === harness.book.structureUndo)
            }
        }

        /// + tag on a card: the Tags tab's rule (no `#`, the book's spelling), Return keeps the field
        /// open and focused for the next, and each tag is a step on that scene's page undo.
        @Test func aCardsTagFieldAddsTagsOnThatScenesPageUndo() async throws {
            try await withScenesSheet { harness, actions in
                actions.startTagging(arrival.id)
                let field = try await harness.tagField()
                try harness.typeTag("#MARA", in: field, on: arrival.id)
                #expect(harness.tags(arrival.id) == ["Mara"], "the book's spelling, without the #")
                #expect(harness.scenes.tagging == arrival.id, "Return keeps the field open")
                #expect(field.stringValue.isEmpty)
                #expect(
                    field.currentEditor() != nil && harness.window.firstResponder === field.currentEditor())
                try harness.typeTag("storm", in: field, on: arrival.id)
                #expect(harness.tags(arrival.id) == ["Mara", "storm"])
                #expect(harness.tags(ferry.id) == ["Mara"], "the open scene is untouched")

                let undo = harness.book.pageUndo(for: arrival.id)
                #expect(undo.undoActionName == TagWording.addUndoName)
                undo.undo()
                #expect(harness.tags(arrival.id) == ["Mara"])
                undo.redo()
                #expect(harness.tags(arrival.id) == ["Mara", "storm"])

                try harness.asAnEvent(on: arrival.id) {
                    #expect(actions.tags.remove("Mara", from: arrival.id))
                }
                #expect(harness.tags(arrival.id) == ["storm"])
                undo.undo()
                #expect(harness.tags(arrival.id) == ["Mara", "storm"], "a chip's × undoes in place")

                try press(.escape, in: harness.window)
                await eventually { harness.scenes.tagging == nil }
                #expect(harness.modes.mode == .scenes, "Esc in the field closes the field, not the sheet")
                try press(.escape, in: harness.window)
                await eventually { harness.modes.mode == .page }
            }
        }

        @Test func theFilterFieldShowsTheCardsWhoseTitleTextOrTagsMatch() async throws {
            try await withScenesSheet { harness, _ in
                let field = try #require(harness.filterField, "precondition: the filter field")
                #expect(harness.window.makeFirstResponder(field))
                let editor = try #require(field.currentEditor() as? NSTextView)
                @MainActor func filter(_ text: String) async -> [SceneID] {
                    editor.selectAll(nil)
                    editor.insertText(text, replacementRange: editor.selectedRange())
                    await eventually { harness.scenes.filter == text }
                    return harness.scenes.cards(of: harness.book.book).map(\.scene.id)
                }
                #expect(await filter("landing") == [arrival.id], "the text")
                #expect(await filter("LETTER") == [letter.id], "a title, ignoring case")
                #expect(await filter("mara") == [ferry.id], "text and tags")
                #expect(await filter("#mara") == [ferry.id], "tags only")
                #expect(await filter("the") == [ferry.id, arrival.id, letter.id])
                #expect(await filter("ghost").isEmpty)
                #expect(await filter("twice") == [letter.id])
                #expect(
                    harness.scenes.cards(of: harness.book.book).map(\.number) == [3], "numbered in the story")

                harness.modes.mode = .page
                await eventually { harness.scenes.filter.isEmpty }
            }
        }

        /// A double click arrives as two clicks: the first selects the card, the second opens it. A
        /// second click landing on another card (something moved it under the pointer) only selects
        /// that one, and a click there then makes the next double click open it.
        @Test func doubleClickingACardOpensItsSceneAndClosesTheSheet() async throws {
            try await withScenesSheet { harness, actions in
                actions.click(.single, on: .card(arrival.id))
                try #require(harness.scenes.clicked == .card(arrival.id), "precondition: the click is kept")
                actions.click(.double, on: .card(letter.id))
                #expect(harness.scenes.focused == letter.id, "the second click on another card selects it")
                #expect(harness.book.openScene == ferry.id, "and opens nothing")
                #expect(harness.modes.mode == .scenes)

                try press(.arrow(.left), in: harness.window)
                try #require(
                    harness.scenes.focused == arrival.id && harness.scenes.clicked == nil,
                    "precondition: the keys moved the focus off the letter and forgot the click")
                actions.click(.double, on: .card(letter.id))
                #expect(
                    harness.book.openScene == ferry.id, "a double click without its first click opens nothing"
                )
                try #require(harness.scenes.focused == letter.id)

                actions.click(.single, on: .card(ferry.id))
                try #require(harness.scenes.focused == ferry.id, "precondition: the letter is unfocused")
                actions.click(.single, on: .card(letter.id))
                actions.click(.double, on: .card(letter.id))
                #expect(harness.book.openScene == letter.id)
                #expect(harness.modes.mode == .page)
                await eventually { harness.pageMirrorsModel && harness.body() == letter.body }
            }
        }

        /// As in the Finder (ADR 0043): a click selects a card at once, taking the keys from the
        /// filter, and opens nothing; the keys then act on that card.
        @Test func aClickSelectsACardWithoutOpeningIt() async throws {
            try await withScenesSheet { harness, actions in
                let filter = try #require(harness.filterField)
                #expect(harness.window.makeFirstResponder(filter))
                try #require(
                    !(harness.window.firstResponder is UndoFocusView), "precondition: the filter has the keys"
                )

                actions.click(.single, on: .card(letter.id))
                #expect(harness.window.firstResponder is UndoFocusView, "the sheet takes the keys")
                #expect(harness.scenes.focused == letter.id)
                #expect(harness.book.openScene == ferry.id, "nothing opens")
                #expect(harness.modes.mode == .scenes, "the sheet stays open")

                actions.click(.single, on: .card(ferry.id))
                #expect(harness.scenes.focused == ferry.id, "another click moves the selection")
                let next = try #require(
                    harness.scenes.grid(of: harness.book.book, harness.preferences.scenesView)
                        .neighbor(of: ferry.id, .right),
                    "precondition: a card right of the ferry")
                try press(.arrow(.right), in: harness.window)
                #expect(harness.scenes.focused == next, "the arrows move on from the clicked card")
                try press(.return, in: harness.window)
                #expect(harness.book.openScene == next, "Return opens the selected card")
                await eventually { harness.modes.mode == .page }
            }
        }

        /// A change to a card's tags (a chip's ×) can move the cards under the pointer, so it forgets
        /// the last click: the double click's second click opens nothing.
        @Test func aTagChangeForgetsTheLastClick() async throws {
            try await withScenesSheet { harness, actions in
                actions.click(.single, on: .card(arrival.id))
                try #require(harness.scenes.clicked == .card(arrival.id), "precondition: the card is clicked")
                #expect(actions.tags.remove("Mara", from: ferry.id))
                await eventually { harness.scenes.clicked == nil }
                #expect(harness.scenes.clicked == nil)
                actions.click(.double, on: .card(arrival.id))
                #expect(harness.book.openScene == ferry.id, "nothing opens")
                #expect(harness.modes.mode == .scenes)
            }
        }

        /// The click count is the system's, from the event the tap ends with.
        @Test func theEventsClickCountSaysSingleOrDouble() throws {
            @MainActor func click(_ count: Int) throws -> CardClick {
                let event = try #require(
                    NSEvent.mouseEvent(
                        with: .leftMouseUp, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                        context: nil, eventNumber: 0, clickCount: count, pressure: 0))
                return CardClick(event)
            }
            #expect(try click(1) == .single)
            #expect(try click(2) == .double)
            #expect(try click(3) == .double)
            #expect(CardClick(nil) == .single, "no event: never opens")
            let key = try #require(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                    context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false,
                    keyCode: 36))
            #expect(CardClick(key) == .single, "a key event has no click count to ask")
        }

        /// The cards' ages move on with the sheet's ticker, once its clock passes a minute and not
        /// before.
        @Test func theCardsAgesRefreshEveryMinute() async throws {
            let clock = ManualClock()
            // The scene was made when the suite first used it, maybe minutes ago: its own time is now.
            let wall = ManualWallTime(at: ferry.modified.date)
            let model = ScenesSheetModel(ticker: MinuteTicker(clock: clock, wallTime: { wall.now }))
            try await withScenesSheet(model: model) { harness, _ in
                let modified = try #require(harness.book.book.scene(ferry.id)?.modified)
                @MainActor func age() -> String { ScenesWording.modified(model.ticker.age(of: modified)) }
                await eventually { clock.sleeperCount == 1 }
                #expect(age() == "just now", "precondition: the sheet's ticker is running")

                wall.advance(.minutes(2))
                clock.advance(by: .seconds(59))
                for _ in 0..<20 { await Task.yield() }
                #expect(age() == "just now", "nothing moves until the minute is up")
                clock.advance(by: .seconds(1))
                await eventually { age() == "2 minutes ago" }
                #expect(age() == "2 minutes ago")
            }
        }

        @Test func aReadOnlyBookShowsTheCardsWithoutAddingOrTagging() async throws {
            try await withScenesSheet(lock: .heldElsewhere) { harness, actions in
                #expect(actions.add(.afterOpenScene) == nil)
                #expect(actions.add(.atEnd) == nil)
                #expect(harness.scenes.titling == nil)
                actions.startTagging(arrival.id)
                #expect(harness.scenes.tagging == nil)
                #expect(!actions.tags.add("storm", to: arrival.id))
                #expect(harness.book.book.scenes.map(\.id) == [ferry.id, arrival.id, letter.id])
                actions.click(.single, on: .card(letter.id))
                #expect(harness.scenes.focused == letter.id, "a card is still selected")
                actions.click(.single, on: .card(arrival.id))
                actions.click(.double, on: .card(arrival.id))
                #expect(harness.book.openScene == arrival.id, "and still opens its scene")
                #expect(harness.modes.mode == .page)
            }
        }
    }
}

extension OneAtATime.BookStoreIntegrationTests {
    /// View → Scenes, on ⌘1 (ADR 0027), opens the sheet over the page of the app's own window,
    /// and chosen again closes it; with no book open it's off. The real menu item and window.
    @Test func theViewMenusScenesItemOpensTheScenesSheet() async throws {
        try await withTemporaryFolder { folder in
            let books = BookController.shared
            try #require(books.store.isChoosing, "precondition: the start screen")
            let title = WindowWording.railName(.scenes)
            let item = try #require(viewMenuItem(title))
            #expect(item.keyEquivalent == "1")
            #expect(
                item.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control]) == [
                    .command
                ])
            await eventually { viewMenuItem(title)?.isEnabled == false }

            let url = folder.appending(path: "Novel.sceneit", directoryHint: .isDirectory)
            #expect(await books.store.create(at: url) == .created)
            try #require(books.store.current?.addScene(after: nil) != nil, "a scene, so the page shows")
            let window = try #require(books.mainWindow, "precondition: the app's main window")
            @MainActor func filterShows() -> Bool {
                subviewTree(of: window.contentView).contains {
                    ($0 as? NSTextField)?.placeholderString == ScenesWording.filterPlaceholder
                }
            }
            await eventually { viewMenuItem(title)?.isEnabled == true }
            try perform(try #require(viewMenuItem(title)))
            await eventually { books.mainWindowChrome.mode?.wrappedValue == .scenes && filterShows() }
            #expect(filterShows(), "the sheet shows")
            try perform(try #require(viewMenuItem(title)))
            await eventually { books.mainWindowChrome.mode?.wrappedValue == .page && !filterShows() }

            let filing = try #require(books.mainWindowChrome.chrome?.keys?.filing)
            filing.begin()
            await eventually { viewMenuItem(title)?.isEnabled == false }
            #expect(viewMenuItem(title)?.isEnabled == false, "not under File a Copy's dialog")
            filing.cancel()
            await eventually { viewMenuItem(title)?.isEnabled == true }
            #expect(await books.store.closeBook() == .left)
            expectNoQuestions()
        }
    }
}

@MainActor
private func anEventReturning<T>(_ undo: UndoManager, _ body: () throws -> T) rethrows -> T {
    undo.beginUndoGrouping()
    defer { undo.endUndoGrouping() }
    return try body()
}

/// The View menu's item titled `title`, after asking the menu to update as AppKit does.
@MainActor
private func viewMenuItem(_ title: String) -> NSMenuItem? {
    if let menu = menuItem(titled: title, in: NSApp.mainMenu)?.menu {
        menu.delegate?.menuNeedsUpdate?(menu)
        menu.update()
    }
    return menuItem(titled: title, in: NSApp.mainMenu)
}

/// The ferry (open, tagged `Mara`), the arrival and the letter in the window, with `boneyard` cut,
/// the Scenes sheet open, with the `ScenesActions` the sheet's buttons call.
func withScenesSheet(
    boneyard: [BookScene] = [], lock: TestBookLock = .ours, model: ScenesSheetModel = ScenesSheetModel(),
    books: BookController = BookController(role: .testHost),
    _ body: (PageHarness, ScenesActions) async throws -> Void
) async throws {
    var tagged = ferry
    tagged.tags = ["Mara"]
    try await withPage(
        [tagged, arrival, letter], boneyard: boneyard, lock: lock, books: books, scenesSheet: model
    ) {
        harness in
        try #require(harness.book.openScene == ferry.id, "precondition: the ferry is open")
        harness.modes.mode = .scenes
        await eventually { harness.filterField != nil }
        try #require(harness.filterField != nil, "precondition: the sheet shows")
        let modes = harness.modes
        let mode = Binding(get: { modes.mode }, set: { modes.mode = $0 })
        let actions = ScenesActions(
            book: harness.book, store: harness.store, preferences: harness.preferences, model: harness.scenes,
            tags: TagActions(book: harness.book, page: harness.page, search: harness.search, mode: mode),
            mode: mode)
        try await body(harness, actions)
    }
}

extension PageHarness {
    fileprivate func tags(_ scene: SceneID) -> [String] {
        book.book.scene(scene)?.tags ?? []
    }

    var filterField: NSTextField? {
        subviewTree(of: window.contentView).compactMap { $0 as? NSTextField }.first {
            $0.placeholderString == ScenesWording.filterPlaceholder
        }
    }

    fileprivate var titleField: AdmittingTextField? {
        subviewTree(of: window.contentView).compactMap { $0 as? AdmittingTextField }.first {
            $0.accessibilityLabel() == ScenesWording.titleLabel
        }
    }

    /// The new card's title field, once it has taken the focus as it appears.
    fileprivate func titleEditor() async throws -> NSTextView {
        await eventually { titleField?.currentEditor() != nil }
        let field = try #require(titleField, "precondition: the new card's title field")
        return try #require(field.currentEditor() as? NSTextView, "precondition: it took the focus")
    }

    fileprivate func acceptTitle(_ title: String) async throws {
        let editor = try await titleEditor()
        editor.insertText(title, replacementRange: editor.selectedRange())
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
    }

    /// A card's + tag field, once it has taken the focus as it opens.
    fileprivate func tagField() async throws -> AdmittingTextField {
        @MainActor func field() -> AdmittingTextField? {
            subviewTree(of: window.contentView).compactMap { $0 as? AdmittingTextField }.first {
                $0.placeholderString == TagWording.addPlaceholder && $0.currentEditor() != nil
            }
        }
        await eventually { field() != nil }
        return try #require(field(), "precondition: the card's + tag field has the focus")
    }

    /// Types `text` into the + tag field, then Return, as one event of `scene`'s page undo.
    fileprivate func typeTag(_ text: String, in field: AdmittingTextField, on scene: SceneID) throws {
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.insertText(text, replacementRange: editor.selectedRange())
        try asAnEvent(on: scene) { editor.doCommand(by: #selector(NSResponder.insertNewline(_:))) }
    }

    fileprivate func asAnEvent(on scene: SceneID, _ body: () throws -> Void) throws {
        let undo = book.pageUndo(for: scene)
        try asSeparateEvents(undo) { try anEvent(undo, body) }
    }

    /// The window's Undo and Redo (the toolbar's and the Edit menu's) read "Undo `undo`" and
    /// "Redo `redo`", or are off where `nil`.
    func expectUndoMenu(undo: String?, redo: String?) async throws {
        let router = try self.undo
        let wanted = UndoState(undo: undo.map { "Undo \($0)" }, redo: redo.map { "Redo \($0)" })
        await eventually { router.state == wanted }
        #expect(router.state == wanted)
    }
}
