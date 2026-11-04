import AppKit
import SceneItCore
import SwiftUI
import Testing

@testable import SceneIt

extension PageHarness {
    /// The Notes tab's editor, while the tab shows.
    var notesView: SceneTextView? {
        subviewTree(of: window.contentView).lazy.compactMap { $0 as? SceneTextView }.first {
            !($0 is ManuscriptTextView) && !$0.isHiddenOrHasHiddenAncestor
        }
    }

    /// Opens the Notes tab, and waits for its editor to show the open scene's notes.
    func showNotes() async throws -> SceneTextView {
        preferences.showRightPanelTab(.notes)
        await eventually { notesView.map(notesMirrorModel) == true }
        return try #require(notesView)
    }

    func notes(_ scene: SceneID? = nil) -> [Paragraph] {
        book.book.scene(scene ?? book.openScene)?.notes ?? []
    }

    /// Whether `view` shows the open scene's notes exactly as the codec renders them.
    func notesMirrorModel(_ view: NSTextView) -> Bool {
        view.textStorage?.isEqual(to: RunCodec.attributedString(forNotes: notes())) == true
    }

    func focusNotes(_ view: NSTextView, at location: Int) {
        #expect(window.makeFirstResponder(view))
        view.setSelectedRange(NSRange(location: location, length: 0))
        window.update()
    }

    /// Which bars are active, the page's and the notes': what each bar's controls are
    /// enabled by, and their tooltips chosen by.
    var activeBars: [TextPart] {
        TextPart.allCases.filter { formatting.selection(in: $0) != nil }
    }
}

private let notesScene: [Paragraph] = [[Run("Check the tides.")], [Run("Dawn in March?")]]

private func sceneWithNotes(
    _ title: SceneTitle, _ body: [Paragraph] = [[Run("The ferry left.")]], notes: [Paragraph] = notesScene,
    _ commented: Commented = .no
) -> BookScene {
    var made = scene(title, body, commented)
    made.notes = notes
    return made
}

@Suite(.serialized, .timeLimit(.minutes(2)))
struct NotesTests {
    @Test func typingInTheNotesReachesBookMdAndNeverTheWordCount() async throws {
        let one = sceneWithNotes("One")
        try await withPage([one]) { page in
            await eventually { page.book.status == .saved }
            let notes = try await page.showNotes()
            #expect(notes.isEditable)
            let words = page.book.manuscriptWordCount
            page.focusNotes(notes, at: ("Check the tides." as NSString).length)
            notes.insertText(" Twice \u{2014} at dawn.", replacementRange: notes.selectedRange())
            let typed: [Paragraph] = [[Run("Check the tides. Twice -- at dawn.")], [Run("Dawn in March?")]]
            #expect(page.notes() == typed, "through the character policy, as on the page")
            #expect(page.notesMirrorModel(notes))
            #expect(page.body() == one.body, "the page is untouched")
            #expect(page.book.status == .unsaved, "autosave heard of it in the same turn")
            #expect(page.book.manuscriptWordCount == words, "notes aren't counted")
            page.store.saveNow()
            await eventually { page.book.status == .saved }
            #expect(try bookOnDisk(page.url).scenes.first?.notes == typed)

            notes.insertNewline(nil)
            notes.insertText("New line.", replacementRange: notes.selectedRange())
            #expect(page.notes() == [typed[0], [Run("New line.")], typed[1]])
            #expect(page.notesMirrorModel(notes))
        }
    }

    @Test func onlyTheFocusedEditorsBarIsActive() async throws {
        try await withPage([sceneWithNotes("One")]) { page in
            let notes = try await page.showNotes()
            page.focusPage(at: 0)
            #expect(page.activeBars == [.body])
            #expect(page.formatting.active?.part == .body)
            #expect(page.formatting.selection(in: .notes) == nil)

            page.focusNotes(notes, at: 0)
            #expect(page.activeBars == [.notes])
            #expect(page.formatting.active?.part == .notes)
            #expect(page.formatting.selection(in: .body) == nil)

            #expect(page.window.makeFirstResponder(page.title))
            #expect(page.activeBars == [])
            #expect(page.formatting.active == nil, "the title is plain text")
            #expect(WindowWording.clickToFormat(.body) == "Click in the page to format")
            #expect(WindowWording.clickToFormat(.notes) == "Click in the notes to format")

            page.focusPage(at: 0)
            #expect(page.formatting.active?.part == .body, "back to the page")
        }
    }

    @Test func theCompactBarFormatsTheNotesAsOneUndoableStep() async throws {
        let one = sceneWithNotes("One")
        try await withPage([one]) { page in
            await eventually { page.book.status == .saved }
            let notes = try await page.showNotes()
            page.focusNotes(notes, at: 0)
            notes.setSelectedRange(NSRange(location: 0, length: ("Check the tides." as NSString).length))
            let undo = try #require(notes.undoManager)
            #expect(undo === page.book.notesUndo(for: one.id), "the notes' own history")
            await eventually { undo.groupingLevel == 0 }
            #expect(page.activeBars == [.notes], "precondition: the compact bar is active")

            page.formatting.perform(.toggle(.bold))
            let formatted: [Paragraph] = [
                [Run("Check the tides.", styles: [.bold])], [Run("Dawn in March?")],
            ]
            await eventually { page.notes() == formatted }
            #expect(page.notesMirrorModel(notes))
            #expect(page.body() == one.body)
            #expect(page.formatting.state(of: .toggle(.bold), in: .notes) == .on)
            #expect(undo.undoActionName == WindowWording.undoName(.toggle(.bold)))
            #expect(!page.book.pageUndo(for: one.id).canUndo, "nothing reaches the page's history")

            page.formatting.perform(.textColor(.red))
            #expect(page.notes().first == [Run("Check the tides.", styles: [.bold], color: .red)])
            page.store.saveNow()
            await eventually { page.book.status == .saved }
            #expect(try bookOnDisk(page.url).scenes.first?.notes == page.notes())

            await undoInAnEvent(undo)
            await undoInAnEvent(undo)
            #expect(page.notes() == notesScene)
            #expect(page.notesMirrorModel(notes))
        }
    }

    @Test func undoGoesToTheNotesWhileTheyHaveTheFocus() async throws {
        let one = sceneWithNotes("One")
        try await withPage([one]) { page in
            let router = try page.undo
            let notes = try await page.showNotes()
            page.focusNotes(notes, at: 0)
            #expect(router.stack == .focusedText)
            #expect(router.manager === page.book.notesUndo(for: one.id))

            notes.insertText("Note: ", replacementRange: notes.selectedRange())
            notes.breakUndoCoalescing()
            await eventually { router.state.undo != nil }
            #expect(page.notes().first == [Run("Note: Check the tides.")])
            router.undo()
            #expect(page.notes() == notesScene)
            #expect(page.body() == one.body)
            #expect(router.state == UndoState(undo: nil, redo: "Redo Typing"))

            page.focusPage(at: 0)
            page.window.update()
            #expect(router.manager === page.book.pageUndo(for: one.id))
            #expect(router.state == .nothing, "the page has no history of the notes' typing")
        }
    }

    /// Like the page and the title, the notes keep what was typed in them in their own scene.
    @Test func openingAnotherSceneKeepsTheNotesTypedInTheOldOne() async throws {
        let one = sceneWithNotes("One")
        let two = sceneWithNotes("Two", [[Run("Second.")]], notes: [[Run("Other notes.")]])
        try await withPage([one, two]) { page in
            let router = try page.undo
            let notes = try await page.showNotes()
            page.focusNotes(notes, at: 0)
            notes.insertText("X", replacementRange: notes.selectedRange())

            page.book.select(two.id)
            await eventually { notes.string == "Other notes." }
            #expect(page.book.book.scene(one.id)?.notes.first == [Run("XCheck the tides.")])
            #expect(page.book.book.scene(two.id)?.notes == two.notes)
            page.window.update()
            #expect(router.manager === page.book.notesUndo(for: two.id))
            #expect(router.state == .nothing, "One's notes history is never offered on Two")
            notes.insertText("Y", replacementRange: notes.selectedRange())
            #expect(page.book.book.scene(two.id)?.notes == [[Run("YOther notes.")]])
            #expect(page.book.book.scene(one.id)?.notes.first == [Run("XCheck the tides.")])
        }
    }

    @Test func theNotesOfAReadOnlyBookCantBeEdited() async throws {
        try await withPage([sceneWithNotes("One")], holdingTheLock: true) { page in
            let notes = try await page.showNotes()
            #expect(!notes.isEditable)
            page.window.makeFirstResponder(notes)
            notes.selectAll(nil)
            #expect(page.formatting.active == nil, "neither bar is active")
            notes.insertText("Typed", replacementRange: notes.selectedRange())
            #expect(page.notes() == notesScene)
        }
    }

    /// Book format §4.2: a comment can cover the notes' text, so a commented span cut from the
    /// page and pasted into the notes keeps its comment, which stays anchored; and back again.
    @Test func aCommentedSpanCutFromThePageKeepsItsCommentInTheNotes() async throws {
        let one = sceneWithNotes("One", letterScene, notes: [[Run("See ")]], .withTooEarly)
        try await withPage([one]) { page in
            let notes = try await page.showNotes()
            try await PageHarness.withPasteboard { pasteboard in
                let letter = NSRange(location: 4, length: 6)
                #expect((page.storage.string as NSString).substring(with: letter) == "letter", "precondition")
                page.window.makeFirstResponder(page.page)
                page.page.setSelectedRange(letter)
                #expect(page.page.writeSelection(to: pasteboard, types: page.page.writablePasteboardTypes))
                page.page.delete(nil)
                #expect(Paragraph.commentIDs(in: page.body()).isEmpty, "precondition: cut from the page")

                page.focusNotes(notes, at: 4)
                #expect(notes.readSelection(from: pasteboard))
                #expect(page.notes() == [[Run("See "), Run("letter", color: .red, comments: [noted])]])
                #expect(page.notesMirrorModel(notes))
                let scene = try #require(page.book.book.scene(one.id))
                #expect(scene.comments.map(\.id) == [noted], "the same comment, not a copy")
                #expect(!scene.isDetached(noted), "anchored in the notes")
                page.store.saveNow()
                await eventually { page.book.status == .saved }
                let saved = try #require(try bookOnDisk(page.url).scenes.first)
                #expect(saved.notes == page.notes())
                #expect(saved.comments.map(\.id) == [noted])

                notes.setSelectedRange(NSRange(location: 4, length: 6))
                pasteboard.clearContents()
                #expect(notes.writeSelection(to: pasteboard, types: notes.writablePasteboardTypes))
                #expect(pasteboard.types?.contains(.pageClip) == true, "the notes write the app's own clip")
                page.focusPage(at: 4)
                #expect(page.page.readSelection(from: pasteboard))
                #expect(page.body() == letterScene, "back on the page, still commented")
                #expect(page.pageMirrorsModel)
            }
        }
    }
}

extension NotesTests {
    /// The owner's picks (#19): Times New Roman 12, 14 pt from the panel's sides and 12 pt from
    /// its top, and 6 pt between paragraphs.
    @Test func theNotesAreSetAsPicked() async throws {
        let empty = sceneWithNotes("Empty", notes: [])
        try await withPage([sceneWithNotes("One"), empty]) { page in
            let notes = try await page.showNotes()
            #expect(notes.textContainerInset == NSSize(width: 14, height: 12))
            let storage = try #require(notes.textStorage)
            #expect(storage.length > 0, "precondition: the notes have text")
            let font = storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
            #expect(font?.familyName == "Times New Roman")
            #expect(font?.pointSize == 12)
            let style = storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
            #expect(style?.paragraphSpacing == 6)
            #expect(style?.lineHeightMultiple == 0, "single-spaced")
            #expect(style?.firstLineHeadIndent == 0)

            page.focusNotes(notes, at: notes.string.utf16.count)
            notes.insertNewline(nil)
            notes.insertText("Typed.", replacementRange: notes.selectedRange())
            let typed =
                notes.textStorage?.attribute(
                    .paragraphStyle, at: notes.string.utf16.count - 1, effectiveRange: nil)
                as? NSParagraphStyle
            #expect(typed?.paragraphSpacing == 6, "a new paragraph has the gap too")
            #expect(page.notes().last == [Run("Typed.")], "the new paragraph reached the model")

            page.book.select(empty.id)
            await eventually { notes.string.isEmpty }
            #expect(page.window.firstResponder === notes, "opening another scene keeps the focus")
        }
    }

    /// Whichever way the notes leave the window while they have the focus, the focus goes back
    /// to the page, so what's typed next goes there.
    @Test func theFocusGoesBackToThePageWhenTheNotesLeave() async throws {
        let one = sceneWithNotes("One", [[Run("Page.")]])
        try await withPage([one]) { page in
            let leaving: [(String, () -> Void, () -> Void)] = [
                (
                    "another tab", { page.preferences.showRightPanelTab(.comments) },
                    { page.preferences.showRightPanelTab(.notes) }
                ),
                (
                    "the panel closed", { page.preferences.setRightPanel(.closed) },
                    { page.preferences.setRightPanel(.open) }
                ),
            ]
            for (way, leave, comeBack) in leaving {
                let notes = try await page.showNotes()
                page.focusNotes(notes, at: 0)
                #expect(page.activeBars == [.notes], "precondition: \(way)")
                leave()
                await eventually { page.notesView == nil }
                #expect(page.window.firstResponder === page.page, "\(way): the page has the focus")
                #expect(page.activeBars == [.body], "\(way): and the page's bar is active")
                let typing = try #require(page.window.firstResponder as? NSTextView)
                #expect(page.body().count == 1, "precondition: one paragraph, the page's whole text")
                let expected = (page.storage.string as NSString).replacingCharacters(
                    in: typing.selectedRange(), with: "X")
                typing.insertText("X", replacementRange: typing.selectedRange())
                #expect(page.body() == [[Run(expected)]], "\(way): typing reaches the page")
                #expect(page.notes() == notesScene, "\(way): and not the notes")
                comeBack()
            }
        }
    }
}

extension BookStoreIntegrationTests {
    /// The real path: the app's own window, store and Format menu, with the notes focused.
    @Test func theFormatMenuFormatsTheNotesWhileTheyHaveTheFocus() async throws {
        try await withTemporaryFolder { folder in
            let books = BookController.shared
            let store = books.store
            try #require(store.current == nil)
            let tab = books.preferences.rightPanelTab
            books.preferences.showRightPanelTab(.notes)
            defer { books.preferences.showRightPanelTab(tab) }
            let url = folder.appending(path: "Novel.sceneit", directoryHint: .isDirectory)
            #expect(await store.create(at: url) == .created)
            let book = try #require(store.current)
            let scene = try #require(book.addScene(after: nil))
            book.replaceBody(of: scene, with: [[Run("The page.")]])
            book.replaceNotes(of: scene, with: [[Run("From the menu.")]])
            @MainActor func notes() -> SceneTextView? {
                NSApp.windows.lazy.flatMap { subviewTree(of: $0.contentView) }
                    .compactMap { $0 as? SceneTextView }
                    .first { !($0 is ManuscriptTextView) && $0.string == "From the menu." }
            }
            await eventually { notes()?.isEditable == true }
            let view = try #require(notes())
            let window = try #require(view.window)
            #expect(window.makeFirstResponder(view))
            view.selectAll(nil)
            await eventually { FormattingCommand.toggle(.italic).menuItem?.isEnabled == true }

            let undo = try #require(view.undoManager)
            #expect(undo === book.notesUndo(for: scene))
            try asSeparateEvents(undo) {
                for command in [FormattingCommand.toggle(.italic), .highlight(.blue)] {
                    try anEvent(undo) { try perform(try #require(command.menuItem, "\(command)")) }
                }
            }
            let formatted: [Paragraph] = [[Run("From the menu.", styles: [.italic], highlight: .blue)]]
            #expect(book.book.scene(scene)?.notes == formatted)
            #expect(book.book.scene(scene)?.body == [[Run("The page.")]], "the menu acts on the notes alone")
            await eventually { FormattingCommand.highlight(.blue).menuItem?.state == .on }
            await eventually { book.status == .saved }
            #expect(try bookOnDisk(url).scenes.first { $0.id == scene }?.notes == formatted)

            window.makeFirstResponder(nil)
            await eventually { FormattingCommand.toggle(.bold).menuItem?.isEnabled == false }
            #expect(await store.closeBook() == .left)
            expectNoQuestions()
        }
    }
}
