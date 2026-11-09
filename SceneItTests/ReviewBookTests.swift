import AppKit
import SceneItCore
import SceneItTestSupport
import Testing

@testable import SceneIt

/// Review Book… in the app's own window (ADR 0029, 0041): a review copy opens with its text
/// read-only on the page, takes comments there and notes in the Notes tab, saves them to its
/// `.review.md` beside the copy, and resumes from it when it's opened again. The open panel is
/// the app's alone: the test host never puts one up, so these start from what the menu item runs
/// with the chosen file, `BookStore.openReview(_:)`.
extension BookStoreIntegrationTests {
    @Test func theFileMenuHasReviewBookAfterOpenBook() throws {
        let item = try #require(menuItem(titled: ReviewWording.menuItem, in: NSApp.mainMenu))
        let menu = try #require(item.menu)
        let open = try #require(menuItem(titled: StoreWording.openBookMenuItem, in: menu))
        #expect(menu.index(of: item) == menu.index(of: open) + 1)
        #expect(item.keyEquivalent.isEmpty, "no shortcut")
    }

    @Test func theTestHostKeepsReviewsAwayFromTheWritersFiles() {
        let books = BookController.shared
        #expect(
            books.reviews.root.path(percentEncoded: false).hasPrefix(
                FileManager.default.temporaryDirectory.path(percentEncoded: false)))
        #expect(books.reviews != ReviewsFolder.standard)
    }

    private static let dawn = SceneID(rawValue: "s1")
    private static let ferry = NSRange(location: 4, length: 5)

    @MainActor
    private static func page(in window: NSWindow) -> ManuscriptTextView? {
        subviewTree(of: window.contentView).lazy.compactMap { $0 as? ManuscriptTextView }.first
    }

    @MainActor
    private static func notes(in window: NSWindow) -> SceneTextView? {
        subviewTree(of: window.contentView).lazy.compactMap { $0 as? SceneTextView }
            .first { $0.editor?.part == .notes }
    }

    @Test func aReviewTakesCommentsAndNotesSavesThemBesideTheCopyAndResumes() async throws {
        try await withTemporaryFolder { folder in
            let books = BookController.shared
            let store = books.store
            try #require(store.isChoosing, "precondition: the start screen")
            let tab = books.preferences.rightPanelTab
            books.preferences.showRightPanelTab(.notes)
            defer { books.preferences.showRightPanelTab(tab) }
            let copy = folder.appending(path: "Tide.md")
            try Data(Self.tide.utf8).write(to: copy)
            let copyBytes = try Data(contentsOf: copy)

            #expect(await store.openReview(copy) == .opened)
            let book = try #require(store.current)
            #expect(book.document.kind == .review)
            let window = try #require(books.mainWindow, "precondition: the app's main window")
            await eventually { Self.page(in: window)?.string == "The ferry left at dawn." }
            let page = try #require(Self.page(in: window))
            #expect(page.editability() == .commentsOnly)
            #expect(page.isEditable, "selectable and commentable")
            let editor = try #require(page.editor)
            let undo = book.pageUndo(for: Self.dawn)

            window.makeFirstResponder(page)
            page.setSelectedRange(NSRange(location: 0, length: 0))
            page.insertText("Not ", replacementRange: page.selectedRange())
            page.setSelectedRange(Self.ferry)
            page.insertText("boat", replacementRange: page.selectedRange())
            page.deleteBackward(nil)
            #expect(page.string == "The ferry left at dawn.", "the copy's text takes no typing")
            #expect(book.book.scene(Self.dawn)?.body == [[Run("The ferry left at dawn.")]])
            #expect(book.status == .saved)

            page.setSelectedRange(Self.ferry)
            var made: CommentID?
            await inAnEvent(undo) { made = editor.newComment() }
            let id = try #require(made, "a comment on the read-only text")
            #expect(
                book.book.scene(Self.dawn)?.body == [
                    [Run("The "), Run("ferry", comments: [id]), Run(" left at dawn.")]
                ])
            await eventually { page.commentPalette.covers(id) }
            undo.undo()
            #expect(book.book.scene(Self.dawn)?.comments.isEmpty == true, "the new comment undoes")
            #expect(page.string == "The ferry left at dawn.")
            undo.redo()
            #expect(book.book.scene(Self.dawn)?.comments.map(\.id) == [id], "and redoes")
            #expect(editor.setText("Which ferry?", ofComment: id))

            await eventually { Self.notes(in: window) != nil }
            let notes = try #require(Self.notes(in: window))
            #expect(notes.editability() == .editable)
            window.makeFirstResponder(notes)
            notes.insertText("Lovely.", replacementRange: notes.selectedRange())
            #expect(book.book.scene(Self.dawn)?.notes == [[Run("Lovely.")]])

            store.saveNow()
            await eventually { book.status == .saved }
            let reviewFile = folder.appending(path: "Tide.review.md")
            let text = try String(decoding: Data(contentsOf: reviewFile), as: UTF8.self)
            #expect(text.contains(#"| c4-9 | "ferry" | Which ferry?"#))
            #expect(text.contains("### Notes\nLovely."))
            #expect(try Data(contentsOf: copy) == copyBytes, "the copy is never written")

            #expect(await store.closeBook() == .left)
            #expect(await store.openReview(copy) == .opened)
            let again = try #require(store.current)
            #expect(again !== book)
            await eventually { Self.page(in: window)?.commentPalette.covers(id) == true }
            #expect(again.book.scene(Self.dawn)?.comments.map(\.text) == ["Which ferry?"])
            #expect(again.book.scene(Self.dawn)?.notes == [[Run("Lovely.")]])
            #expect(await store.closeBook() == .left)
            #expect(try Data(contentsOf: copy) == copyBytes)
            expectNoQuestions()
        }
    }

    @Test func aDamagedReviewOpensReadOnlyInTheWindowUntilMakeEditable() async throws {
        try await withTemporaryFolder { folder in
            let books = BookController.shared
            let store = books.store
            try #require(store.isChoosing, "precondition: the start screen")
            let copy = folder.appending(path: "Tide.md")
            try Data(Self.tide.utf8).write(to: copy)
            let damaged = Self.fm + "\n\nStray line.\n"
            let reviewFile = folder.appending(path: "Tide.review.md")
            try Data(damaged.utf8).write(to: reviewFile)

            guard case .openedReadOnly(.repairedOnOpen) = await store.openReview(copy) else {
                Issue.record("expected the damaged review to open read-only")
                return
            }
            #expect((books.prompts as? HeadlessPrompts)?.takeTitles() == [ReadOnlyWording.readOnlyTitle])
            let window = try #require(books.mainWindow)
            await eventually { Self.page(in: window)?.string == "The ferry left at dawn." }
            let page = try #require(Self.page(in: window))
            #expect(page.editability() == .readOnly)
            page.setSelectedRange(Self.ferry)
            #expect(page.editor?.newComment() == nil, "nothing changes while it's read-only")
            #expect(try Data(contentsOf: reviewFile) == Data(damaged.utf8))

            #expect(await store.makeEditable() == .editable)
            #expect(page.editability() == .commentsOnly)
            #expect(await store.closeBook() == .left)
            #expect(
                try String(decoding: Data(contentsOf: reviewFile), as: UTF8.self).contains(
                    "- [line] Stray line."))
            expectNoQuestions()
        }
    }

    private static let tide = """
        ---
        title: Tide
        format: 2
        export: 01JDB2C7Q9X4M8T6V3N5R1K0PZ
        exported: 2026-11-03T10:15:00-08:00
        ---

        ## Dawn
        id: s1
        modified: 2026-11-02T09:00:00-08:00

        The ferry left at dawn.

        ## Dusk
        id: s2
        modified: 2026-11-02T09:00:00-08:00

        The gulls came home.

        """

    private static let fm = """
        ---
        title: Tide
        format: 1
        copy: 01JDB2C7Q9X4M8T6V3N5R1K0PZ
        id: 01JDD8WQ4K7M2N9P3R5S6T8V0X
        ---
        """
}
