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
extension OneAtATime.BookStoreIntegrationTests {
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
            let (copy, _) = try Self.writeCopy(in: folder)
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
            let (copy, export) = try Self.writeCopy(in: folder)
            var ids = IDGenerator.system
            let damaged = Self.frontMatter(copy: export, id: ids.reviewID()) + "\n\nStray line.\n"
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

    private static let dawnWord = NSRange(location: 18, length: 4)
    private static let left = NSRange(location: 10, length: 4)

    @MainActor
    private static func card(_ comment: CommentID, in window: NSWindow) -> CommentTextView? {
        subviewTree(of: window.contentView).lazy.compactMap { $0 as? CommentTextView }
            .first { $0.comment == comment }
    }

    @MainActor
    private static func menuControl(of comment: CommentID, in window: NSWindow) -> CommentMenuButton.Control?
    {
        subviewTree(of: window.contentView).lazy.compactMap { $0 as? CommentMenuButton.Control }
            .first { $0.comment == comment }
    }

    /// The window's undo router, as Edit → Undo and the toolbar use it.
    @MainActor
    private static func router(in window: NSWindow) -> UndoRouter? {
        subviewTree(of: window.contentView).lazy.compactMap { ($0 as? UndoRouterWindow.WindowView)?.router }
            .first
    }

    /// The Comments tab shown while `body` runs, and the panel put back after.
    @MainActor
    private static func withCommentsTab(_ books: BookController, _ body: () async throws -> Void)
        async rethrows
    {
        let preferences = books.preferences
        let (panel, tab) = (preferences.rightPanel, preferences.rightPanelTab)
        defer {
            preferences.setRightPanel(panel)
            preferences.showRightPanelTab(tab)
        }
        preferences.reveal(.comments)
        try await body()
    }

    /// The owner's bug: on a review's page, New Comment worked only when called directly, since
    /// the page took the focus for formatting alone. Edit → New Comment, the floating Comment
    /// button and the Comments tab's + each comment the selection, through the window as the
    /// reviewer reaches them, while the format bar and the Format menu stay off.
    @Test func aReviewsPageTakesNewCommentsFromTheMenuTheButtonAndThePlus() async throws {
        try await withTemporaryFolder { folder in
            let books = BookController.shared
            let store = books.store
            try #require(store.isChoosing, "precondition: the start screen")
            try await Self.withCommentsTab(books) {
                let (copy, _) = try Self.writeCopy(in: folder)
                #expect(await store.openReview(copy) == .opened)
                let book = try #require(store.current)
                let window = try #require(books.mainWindow)
                await eventually { Self.page(in: window)?.string == "The ferry left at dawn." }
                let page = try #require(Self.page(in: window))
                try #require(page.editability() == .commentsOnly, "precondition: a review's page")
                let editor = try #require(page.editor)
                let formatting = books.formatting

                window.makeFirstResponder(page)
                page.setSelectedRange(NSRange(location: 2, length: 0))
                await eventually { formatting.active?.part == .body }
                #expect(formatting.active?.formats == .fixed)
                #expect(formatting.commentablePage == nil, "a caret isn't enough")
                #expect(page.commentButton.isHidden)
                #expect(newCommentItem()?.isEnabled == false)

                page.setSelectedRange(Self.ferry)
                await eventually { formatting.commentablePage === editor }
                #expect(formatting.commentablePage === editor)
                #expect(formatting.selection == nil, "the Format menu has nothing to format")
                #expect(formatting.selection(in: .body) == nil, "the page's format bar is off")
                await eventually { FormattingCommand.toggle(.bold).menuItem != nil }
                #expect(FormattingCommand.toggle(.bold).menuItem?.isEnabled == false, "Format → Bold is off")
                #expect(!page.commentButton.isHidden, "the Comment button shows")

                await eventually { newCommentItem()?.isEnabled == true }
                try perform(try #require(newCommentItem()))
                let fromMenu = try #require(
                    book.book.scene(Self.dawn)?.comments.last?.id, "Edit → New Comment")
                #expect(page.textStorage?.ranges(commentedBy: fromMenu) == [Self.ferry])
                await eventually { window.firstResponder === Self.card(fromMenu, in: window) }
                let card = try #require(Self.card(fromMenu, in: window), "its card has the focus")
                card.insertText("Which ferry?", replacementRange: card.selectedRange())
                #expect(book.book.scene(Self.dawn)?.comment(fromMenu)?.text == "Which ferry?")

                window.makeFirstResponder(page)
                page.setSelectedRange(Self.dawnWord)
                await eventually { !page.commentButton.isHidden }
                try #require(!page.commentButton.isHidden, "precondition: the button shows")
                page.commentButton.performClick(nil)
                let fromButton = try #require(book.book.scene(Self.dawn)?.comments.last?.id)
                #expect(fromButton != fromMenu, "the Comment button")
                #expect(page.textStorage?.ranges(commentedBy: fromButton) == [Self.dawnWord])

                window.makeFirstResponder(page)
                page.setSelectedRange(Self.left)
                await eventually { formatting.commentablePage === editor }
                CommentsTab.addComment(through: formatting)
                let fromPlus = try #require(book.book.scene(Self.dawn)?.comments.last?.id)
                #expect(![fromMenu, fromButton].contains(fromPlus), "the Comments tab's +")
                #expect(page.textStorage?.ranges(commentedBy: fromPlus) == [Self.left])

                window.makeFirstResponder(page)
                let router = try #require(Self.router(in: window))
                #expect(book.pageUndo(for: Self.dawn).undoActionName == CommentWording.newComment)
                router.undo()
                #expect(book.book.scene(Self.dawn)?.comment(fromPlus) == nil, "Edit → Undo takes it back")
                #expect(page.textStorage?.ranges(commentedBy: fromPlus).isEmpty == true)
                router.redo()
                #expect(book.book.scene(Self.dawn)?.comment(fromPlus) != nil, "and Redo brings it back")
                #expect(page.string == "The ferry left at dawn.")
                #expect(book.book.scene(Self.dawn)?.body.map(\.text) == ["The ferry left at dawn."])

                store.saveNow()
                await eventually { book.status == .saved }
                let text = try String(
                    decoding: Data(contentsOf: folder.appending(path: "Tide.review.md")), as: UTF8.self)
                #expect(text.contains(#"| c4-9 | "ferry" | Which ferry?"#))
                #expect(await store.closeBook() == .left)
            }
            expectNoQuestions()
        }
    }

    /// A card's ⋯ menu on a review: Re-anchor puts a detached comment on the page's selection,
    /// recolor and Dismiss work, each one step on the page's undo; and the notes, which a review
    /// takes, can be formatted.
    @Test func aReviewsCardMenuReanchorsRecolorsAndDismisses() async throws {
        try await withTemporaryFolder { folder in
            let books = BookController.shared
            let store = books.store
            try #require(store.isChoosing, "precondition: the start screen")
            try await Self.withCommentsTab(books) {
                let (copy, export) = try Self.writeCopy(in: folder)
                var ids = IDGenerator.system
                let anchored = CommentID(rawValue: "c1")
                let detached = CommentID(rawValue: "c2")
                let review =
                    Self.frontMatter(copy: export, id: ids.reviewID()) + """


                        ## Dawn
                        id: s1

                        ### Comments
                        - c1 | red | 2026-11-04T09:12:00-08:00 | c4-9 | "ferry" | Which ferry?
                        - c2 | gray | 2026-11-04T09:30:00-08:00 | detached | Too short?

                        """
                try Data(review.utf8).write(to: folder.appending(path: "Tide.review.md"))
                #expect(await store.openReview(copy) == .opened)
                let book = try #require(store.current)
                try #require(
                    book.book.scene(Self.dawn)?.isDetached(detached) == true, "precondition: detached")
                let window = try #require(books.mainWindow)
                await eventually { Self.page(in: window)?.commentPalette.covers(anchored) == true }
                let page = try #require(Self.page(in: window))
                let editor = try #require(page.editor)
                let undo = book.pageUndo(for: Self.dawn)
                let router = try #require(Self.router(in: window))

                window.makeFirstResponder(page)
                page.setSelectedRange(Self.dawnWord)
                await eventually { books.formatting.commentablePage === editor }
                editor.comments.select(detached, in: Self.dawn)
                await eventually { Self.menuControl(of: detached, in: window) != nil }
                let reanchorMenu = try #require(
                    Self.menuControl(of: detached, in: window)?.makeMenu?() ?? nil)
                let reanchor = try #require(reanchorMenu.items.first { $0.title == CommentWording.reanchor })
                #expect(reanchor.isEnabled)
                await inAnEvent(undo) { try? perform(reanchor) }
                #expect(page.textStorage?.ranges(commentedBy: detached) == [Self.dawnWord])
                #expect(book.book.scene(Self.dawn)?.isDetached(detached) == false)
                #expect(undo.undoActionName == CommentWording.reanchorUndoName)
                try #require(window.firstResponder === page, "precondition: the page has the focus")
                router.undo()
                #expect(book.book.scene(Self.dawn)?.isDetached(detached) == true, "Undo detaches it again")
                router.redo()
                #expect(page.textStorage?.ranges(commentedBy: detached) == [Self.dawnWord], "Redo re-anchors")

                editor.comments.select(anchored, in: Self.dawn)
                await eventually { Self.menuControl(of: anchored, in: window) != nil }
                let control = try #require(Self.menuControl(of: anchored, in: window))
                let recolorMenu = try #require(control.makeMenu?() ?? nil)
                let blue = try #require(recolorMenu.items.first { CommentMenu.color(of: $0) == .blue })
                await inAnEvent(undo) { try? perform(blue) }
                #expect(book.book.scene(Self.dawn)?.comment(anchored)?.color == .blue, "recolored")

                let dismissMenu = try #require(control.makeMenu?() ?? nil)
                let dismiss = try #require(dismissMenu.items.first { $0.title == CommentWording.dismiss })
                await inAnEvent(undo) { try? perform(dismiss) }
                #expect(book.book.scene(Self.dawn)?.comment(anchored) == nil, "dismissed")
                #expect(page.textStorage?.ranges(commentedBy: anchored).isEmpty == true)
                window.makeFirstResponder(page)
                router.undo()
                #expect(book.book.scene(Self.dawn)?.comment(anchored)?.color == .blue, "Undo restores it")
                #expect(page.textStorage?.ranges(commentedBy: anchored) == [Self.ferry])
                #expect(book.book.scene(Self.dawn)?.body.map(\.text) == ["The ferry left at dawn."])

                books.preferences.showRightPanelTab(.notes)
                await eventually { Self.notes(in: window) != nil }
                let notes = try #require(Self.notes(in: window))
                window.makeFirstResponder(notes)
                await eventually { books.formatting.active?.part == .notes }
                #expect(books.formatting.selection(in: .notes) != nil, "the notes' format bar is on")
                #expect(books.formatting.commentablePage == nil, "the notes take no comments")
                notes.insertText("Lovely.", replacementRange: notes.selectedRange())
                #expect(book.book.scene(Self.dawn)?.notes == [[Run("Lovely.")]])
                #expect(await store.closeBook() == .left)
            }
            expectNoQuestions()
        }
    }

    /// The TIDE copy, with an export id of its own: the test host's reviews folder is shared, and
    /// a new review's lock is keyed by its copy's export id.
    private static func tide(_ export: ExportID) -> String {
        """
        ---
        title: Tide
        format: 2
        export: \(export)
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
    }

    private static func frontMatter(copy: ExportID, id: ReviewID) -> String {
        """
        ---
        title: Tide
        format: 1
        copy: \(copy)
        id: \(id)
        ---
        """
    }

    /// A fresh copy, `Tide.md` in `folder`.
    @MainActor
    private static func writeCopy(in folder: URL) throws -> (URL, ExportID) {
        var ids = IDGenerator.system
        let export = ids.exportID()
        let copy = folder.appending(path: "Tide.md")
        try Data(tide(export).utf8).write(to: copy)
        return (copy, export)
    }

    /// Stands in for the color panel as `changeColor:`'s sender, which is asked only its color.
    private final class ColorSender: NSObject {
        @objc let color = NSColor.systemRed
    }

    /// The page of a review takes no change to its text or styles from any of the ways the system
    /// offers them (the Font menu's Underline, the color panel, paste, Bold, Find's Replace), and
    /// stays in step with the model, so a comment made on it afterwards is the model's too.
    @Test func aReviewPageTakesNoChangeToItsTextOrStylesAndStaysInStep() async throws {
        try await withTemporaryFolder { folder in
            let books = BookController.shared
            let store = books.store
            try #require(store.isChoosing, "precondition: the start screen")
            let (copy, _) = try Self.writeCopy(in: folder)
            #expect(await store.openReview(copy) == .opened)
            let book = try #require(store.current)
            let window = try #require(books.mainWindow)
            await eventually { Self.page(in: window)?.string == "The ferry left at dawn." }
            let page = try #require(Self.page(in: window))
            let storage = try #require(page.textStorage)
            @MainActor func inStep() -> Bool {
                storage.isEqual(
                    to: RunCodec.attributedString(forBody: book.book.scene(Self.dawn)?.body ?? []))
            }
            try #require(inStep(), "precondition: the page shows the model")
            let before = book.book.scene(Self.dawn)?.body
            window.makeFirstResponder(page)

            page.setSelectedRange(Self.ferry)
            page.underline(nil)
            page.changeColor(ColorSender())
            #expect(inStep(), "Underline and the color panel change nothing")
            #expect(book.book.scene(Self.dawn)?.body == before)

            try await PageHarness.withPasteboard { pasteboard in
                pasteboard.clearContents()
                pasteboard.setString("boat", forType: .string)
                page.setSelectedRange(Self.ferry)
                #expect(!page.readSelection(from: pasteboard), "paste is refused")
            }
            page.setSelectedRange(Self.ferry)
            await eventually { FormattingCommand.toggle(.bold).menuItem != nil }
            #expect(FormattingCommand.toggle(.bold).menuItem?.isEnabled == false, "Format → Bold (⌘B) is off")
            #expect(page.editor?.format(.toggle(.bold)) == false)
            #expect(books.formatting.selection == nil, "the format bar has nothing to format")

            let replace = NSMenuItem(
                title: "Replace", action: #selector(NSTextView.performTextFinderAction(_:)), keyEquivalent: ""
            )
            replace.tag = NSTextFinder.Action.showReplaceInterface.rawValue
            #expect(!page.validateUserInterfaceItem(replace), "Find has no Replace")
            let find = NSMenuItem(
                title: "Find", action: #selector(NSTextView.performTextFinderAction(_:)), keyEquivalent: "")
            find.tag = NSTextFinder.Action.showFindInterface.rawValue
            #expect(page.validateUserInterfaceItem(find), "Find itself works")

            let click = try #require(
                NSEvent.mouseEvent(
                    with: .rightMouseDown, location: NSPoint(x: 10, y: 10), modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                    pressure: 1))
            let menu = try #require(page.menu(for: click))
            @MainActor func actions(_ menu: NSMenu) -> [Selector] {
                menu.items.flatMap { [$0.action].compactMap { $0 } + ($0.submenu.map(actions) ?? []) }
            }
            let offered = Set(actions(menu))
            for action in [
                #selector(NSText.paste(_:)), #selector(NSText.cut(_:)), #selector(NSTextView.underline(_:)),
            ] {
                #expect(!offered.contains(action), "the menu offers no \(action)")
            }
            #expect(offered.contains(#selector(NSText.copy(_:))), "Copy stays")
            #expect(inStep())
            #expect(book.book.scene(Self.dawn)?.body == before)

            page.setSelectedRange(NSRange(location: 0, length: 23))
            let undo = book.pageUndo(for: Self.dawn)
            var made: CommentID?
            await inAnEvent(undo) { made = page.editor?.newComment() }
            let id = try #require(made)
            #expect(book.book.scene(Self.dawn)?.comments.map(\.id) == [id])
            #expect(book.book.scene(Self.dawn)?.body == [[Run("The ferry left at dawn.", comments: [id])]])
            #expect(inStep())
            #expect(await store.closeBook() == .left)
            expectNoQuestions()
        }
    }
}
