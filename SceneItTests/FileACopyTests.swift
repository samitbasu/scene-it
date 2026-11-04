import AppKit
import SceneItCore
import SwiftUI
import Testing

@testable import SceneIt

/// File a Copy in the app (PLAN §7.1), through a test-host store, the dialog's real tag and
/// note editors and the action its File copy button runs. Each test has its own store: the
/// app's own belongs to `BookStoreIntegrationTests`, which may run at the same time.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct FileACopyTests {
    @Test func theFileMenuHasFileACopy() {
        #expect(menuItem(titled: ArchiveWording.menuItem, in: NSApp.mainMenu) != nil)
    }

    private static let newline = #selector(NSResponder.insertNewline(_:))
    private static let deleteBackward = #selector(NSResponder.deleteBackward(_:))

    /// The tag field and its coordinator, as the dialog makes them, editing `flow`'s draft.
    private static func tagField(_ flow: FilingFlow) throws -> (
        TagTextField.Coordinator, AdmittingTextField, AdmittingTextView
    ) {
        let coordinator = TagTextField.Coordinator(
            draft: Binding(get: { flow.draft! }, set: { flow.draft = $0 }))
        let field = TagTextField.field("", coordinator)
        return (coordinator, field, try #require(field.editor))
    }

    @Test func filingThroughTheDialogFilesALockedExactCopyAndShowsTheToast() async throws {
        try await withTemporaryFolder { folder in
            let books = BookController(role: .testHost)
            let store = books.store
            let url = folder.appending(path: "Novel 32.sceneit", directoryHint: .isDirectory)
            #expect(await store.create(at: url) == .created)
            let book = try #require(store.current)
            let scene = try #require(book.addScene(after: nil))
            book.replaceBody(of: scene, with: [[Run("The ferry left at dawn.")]])

            let flow = FilingFlow(book: book)
            let today = try #require(CalendarDay(year: 2026, month: 11, day: 3))
            flow.begin(today: today)
            let (tags, field, editor) = try Self.tagField(flow)
            for tag in ["draft 4", "oops"] {
                editor.insertText(tag, replacementRange: NSRange(location: 0, length: 0))
                try await Task.sleep(for: .milliseconds(50))
                #expect(editor.undoManager?.canUndo == true, "precondition: the typing can be undone")
                #expect(tags.control(field, textView: editor, doCommandBy: Self.newline))
                #expect(editor.string.isEmpty, "Return empties the field")
                #expect(editor.undoManager?.canUndo == false, "the added tag's text can't be undone back")
            }
            #expect(tags.control(field, textView: editor, doCommandBy: Self.deleteBackward))
            #expect(flow.draft?.tags == ["draft 4"], "⌫ in the empty field removed the last chip")
            editor.insertText("x", replacementRange: NSRange(location: 0, length: 0))
            #expect(!tags.control(field, textView: editor, doCommandBy: Self.deleteBackward))
            editor.string = ""
            flow.draft?.pendingTag = ""
            let notes = NoteTextView.Coordinator(
                draft: Binding(get: { flow.draft! }, set: { flow.draft = $0 }))
            withExtendedLifetime(notes) {
                NoteTextView.editor(notes).insertText(
                    "Before the ending rewrite", replacementRange: NSRange(location: 0, length: 0))
            }
            #expect(flow.draft?.note == "Before the ending rewrite", "the note reaches the draft")
            withExtendedLifetime(tags) {}

            let result = await flow.confirm(in: store)

            guard case .filed(let outcome)? = result else {
                Issue.record("expected a filed copy, got \(String(describing: result))")
                return
            }
            #expect(outcome.isComplete)
            #expect(flow.draft == nil, "the dialog closed")
            #expect(book.filingDraft == nil)
            #expect(flow.toast?.text == ArchiveWording.toast(FilingRecord(filed: today, tags: ["draft 4"])))
            let layout = PackageLayout(root: url)
            let copy = layout.filedCopy(FiledCopyNumber.first)
            #expect(try Data(contentsOf: copy) == (try Data(contentsOf: layout.book)))
            #expect(try bookOnDisk(url) == book.book, "the edit was saved before filing")
            let attributes = try FileManager.default.attributesOfItem(
                atPath: copy.path(percentEncoded: false))
            #expect(attributes[.immutable] as? Bool == true)
            #expect(book.archive.copies.map(\.tags) == [["draft 4"]])
            #expect(book.archive.copies.map(\.note) == ["Before the ending rewrite"])
            #expect(await store.closeBook() == .left)
            let headless = try #require(books.prompts as? HeadlessPrompts)
            #expect(headless.takeTitles() == [], "a complete filing raises no alert")
        }
    }

    @Test func undoAndRedoInTheTagFieldKeepTheDraftInStep() async throws {
        try await withTemporaryFolder { folder in
            let books = BookController(role: .testHost)
            let url = folder.appending(path: "Undo 32.sceneit", directoryHint: .isDirectory)
            #expect(await books.store.create(at: url) == .created)
            let flow = FilingFlow(book: try #require(books.store.current))
            flow.begin()
            let (tags, field, editor) = try Self.tagField(flow)
            editor.insertText("draft", replacementRange: NSRange(location: 0, length: 0))
            tags.controlTextDidChange(
                Notification(
                    name: NSControl.textDidChangeNotification, object: field,
                    userInfo: ["NSFieldEditor": editor]))
            #expect(flow.draft?.pendingTag == "draft")
            try await Task.sleep(for: .milliseconds(50))
            let history = try #require(editor.undoManager)
            history.undo()
            #expect(editor.string.isEmpty)
            #expect(flow.draft?.pendingTag == "", "undo reaches the draft")
            history.redo()
            #expect(flow.draft?.pendingTag == "draft", "and so does redo")
            withExtendedLifetime(tags) {}
            flow.cancel()
            #expect(await books.store.closeBook() == .left)
        }
    }

    @Test func aFilingThatFailsKeepsTheDialogOpenWithWhatWasTyped() async throws {
        try await withTemporaryFolder { folder in
            let books = BookController(role: .testHost)
            let store = books.store
            let url = folder.appending(path: "Failing 32.sceneit", directoryHint: .isDirectory)
            #expect(await store.create(at: url) == .created)
            let layout = PackageLayout(root: url)
            try FileManager.default.removeItem(at: layout.archive)
            try Data("not a folder".utf8).write(to: layout.archive)
            let flow = FilingFlow(book: try #require(store.current))
            flow.begin()
            flow.draft?.pendingTag = "draft 4"
            flow.draft?.commitPendingTag()
            flow.draft?.note = "Keep me"
            let typed = flow.draft

            let result = await flow.confirm(in: store)

            #expect(result == .failed(.archiveNotAFolder))
            #expect(flow.draft == typed, "the dialog is still up, as the writer left it")
            #expect(flow.stage == .editing)
            #expect(flow.toast == nil)
            #expect((books.prompts as? HeadlessPrompts)?.takeTitles() == ["Scene It couldn't file a copy."])
            flow.cancel()
            #expect(await store.closeBook() == .left)
        }
    }

    /// `view` in an offscreen window of its own, laid out, for `body`; the window is closed after.
    @MainActor
    private static func inWindow<T>(_ view: some View, _ body: (NSWindow) async throws -> T) async throws -> T
    {
        let window = NSWindow(
            contentRect: NSRect(x: -30000, y: -30000, width: 500, height: 400), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            window.close()
        }
        try await Task.sleep(for: .milliseconds(500))
        return try await body(window)
    }

    /// The dialog's tags and note go through the character policy as the editors do (ADR
    /// 0028): what's typed or pasted is transliterated to ASCII as it arrives, as one undoable
    /// step on the editor's real history, with no input method and on TextKit 2.
    @Test func theTagAndNoteEditorsAdmitWhatsTypedAndPastedThroughTheCharacterPolicy() async throws {
        let typed = "caf\u{E9} \u{2014} \u{201C}na\u{EF}ve\u{201D}"
        #expect(
            CharacterPolicy.admittedLine(typed) == "cafe -- \"naive\"",
            "precondition: the policy transliterates")
        let flow = DraftBox(FilingDraft(today: try #require(CalendarDay(year: 2026, month: 11, day: 3))))
        let dialog = FileACopyDialog(
            draft: Binding(get: { flow.draft }, set: { flow.draft = $0 }), stage: .editing, cancel: {},
            confirm: {})
        try await Self.inWindow(dialog) { window in
            let views = subviewTree(of: window.contentView)
            let field = try #require(views.compactMap { $0 as? AdmittingTextField }.first)
            let note = try #require(views.compactMap { $0 as? AdmittingTextView }.first, "the note's editor")
            #expect(window.makeFirstResponder(field))
            let tagEditor = try #require(
                field.currentEditor() as? AdmittingTextView, "the field's own editor")
            for (editor, admit, kept) in [
                (tagEditor, CharacterPolicy.admittedLine, { flow.draft.pendingTag }),
                (note, CharacterPolicy.admittedInput, { flow.draft.note }),
            ] {
                if editor === note { #expect(window.makeFirstResponder(note)) }
                #expect(editor.inputContext == nil, "no input method")
                #expect(editor.textLayoutManager != nil, "TextKit 2")
                let history = try #require(editor.undoManager)
                if editor === note {
                    #expect(history === window.undoManager, "the note undoes as the window does")
                }
                history.removeAllActions()
                for paste in [false, true] {
                    if paste {
                        try await PageHarness.withPasteboard { pasteboard in
                            pasteboard.clearContents()
                            pasteboard.setString(typed, forType: .string)
                            #expect(editor.readSelection(from: pasteboard))
                        }
                    } else {
                        editor.insertText(typed, replacementRange: editor.selectedRange())
                    }
                    let how = paste ? "pasted" : "typed"
                    #expect(editor.string == admit(typed), "\(how)")
                    #expect(kept() == admit(typed), "the draft holds what's shown, \(how)")
                    let isASCII = editor.string.unicodeScalars.allSatisfy { $0.isASCII }
                    #expect(isASCII)
                    #expect(
                        editor.selectedRange()
                            == NSRange(location: (editor.string as NSString).length, length: 0),
                        "the caret follows the admitted text, \(how)")
                    try await Task.sleep(for: .milliseconds(50))
                    history.undo()
                    #expect(editor.string.isEmpty, "one undo takes it back, \(how)")
                    #expect(!history.canUndo, "it was one step, \(how)")
                }
            }
        }
    }

    /// The title field as `NSTextField(string:)` made it on main: the same font, and it scrolls
    /// sideways so the caret stays visible in a title wider than the field.
    @Test func theTitleFieldScrollsAndKeepsItsFont() async throws {
        try await withTemporaryFolder { folder in
            let books = BookController(role: .testHost)
            let store = books.store
            let url = folder.appending(path: "Title 32.sceneit", directoryHint: .isDirectory)
            #expect(await store.create(at: url) == .created)
            let book = try #require(store.current)
            let scene = try #require(book.addScene(after: nil))
            book.setTitle(of: scene, to: SceneTitle(String(repeating: "A very long scene title ", count: 12)))
            let window = BookWindow(
                book: book, store: store, preferences: books.preferences,
                formatting: EditorFormatting(preferences: books.preferences), mode: .constant(.page))
            let fieldsMatch = { (field: NSTextField) in field.font == NSTextField(string: "").font }
            try await WindowRenders.withWindow(window) { window in
                let title = try #require(
                    subviewTree(of: window.contentView).compactMap { $0 as? AdmittingTextField }.first {
                        $0.placeholderString == WindowWording.untitledScene
                    })
                #expect(window.makeFirstResponder(title))
                let editor = try #require(title.currentEditor() as? NSTextView)
                let end = (editor.string as NSString).length
                editor.setSelectedRange(NSRange(location: end, length: 0))
                editor.scrollRangeToVisible(NSRange(location: end, length: 0))
            } capture: { window in
                let title = try #require(
                    subviewTree(of: window.contentView).compactMap { $0 as? AdmittingTextField }.first {
                        $0.placeholderString == WindowWording.untitledScene
                    })
                #expect(title.cell?.isScrollable == true)
                let onMain = NSTextField(string: "")
                onMain.lineBreakMode = .byTruncatingTail
                onMain.cell?.isScrollable = true
                #expect(
                    title.lineBreakMode == onMain.lineBreakMode, "as main's order of setting them leaves it")
                #expect(fieldsMatch(title), "the font NSTextField(string:) gives")
                let editor = try #require(title.currentEditor() as? NSTextView)
                #expect(
                    editor.frame.width > title.bounds.width, "precondition: the title is wider than the field"
                )
                let clip = try #require(editor.superview as? NSClipView)
                #expect(clip.bounds.minX > 0, "scrolled so the caret at the end shows")
            }
            let tags = TagTextField.field(
                "",
                TagTextField.Coordinator(
                    draft: .constant(FilingDraft(today: CalendarDay(.now, in: .current)))))
            #expect(fieldsMatch(tags), "and so does the tag field")
            #expect(tags.cell?.isScrollable == true)
            #expect(await store.closeBook() == .left)
        }
    }

    /// File a Copy on a book that opened read-only: nothing is filed, and the writer is told.
    /// (The toolbar button and the menu item are disabled for such a book; this is what
    /// happens if a filing gets through anyway.)
    @Test func fileACopyOnAReadOnlyBookFilesNothingAndSaysSo() async throws {
        try await withTemporaryFolder { folder in
            let books = BookController(role: .testHost)
            let store = books.store
            let url = folder.appending(path: "Held 32.sceneit", directoryHint: .isDirectory)
            let holder = try BookPackage.create(at: url, title: "Held")
            #expect(await store.open(url) == .openedReadOnly(.openElsewhere))
            let book = try #require(store.current)
            #expect(!book.isEditable, "precondition: read-only")
            let headless = try #require(books.prompts as? HeadlessPrompts)
            _ = headless.takeTitles()
            let flow = FilingFlow(book: book)
            flow.begin()

            #expect(await flow.confirm(in: store) == .unavailable)

            #expect(headless.takeTitles() == ["Scene It couldn't file a copy."])
            #expect(flow.draft == nil)
            #expect(
                try FileManager.default.contentsOfDirectory(
                    atPath: PackageLayout(root: url).archive.path(percentEncoded: false)) == ["index.md"])
            #expect(await store.closeBook() == .left)
            _ = holder
        }
    }

    /// The page stays the book window's first responder behind the sheet, so Undo must look in
    /// the sheet: undoing there acts on the dialog's field and leaves the scene as it was.
    @Test func undoWhileTheDialogIsUpActsInTheDialogNotOnThePage() async throws {
        try await withTemporaryFolder { folder in
            let books = BookController(role: .testHost)
            let store = books.store
            let url = folder.appending(path: "Sheet 32.sceneit", directoryHint: .isDirectory)
            #expect(await store.create(at: url) == .created)
            let book = try #require(store.current)
            let scene = try #require(book.addScene(after: nil))
            let filing = FilingFlow(book: book)
            let router = UndoRouter(book: book)
            let window = BookWindow(
                book: book, store: store, preferences: books.preferences,
                formatting: EditorFormatting(preferences: books.preferences), mode: .constant(.page),
                filing: filing)
            filing.begin()
            // Typing happens before the capture, so the run loop closes each undo group.
            let (before, after) = try await WindowRenders.withWindow(window) { window in
                let sheet = try #require(window.attachedSheet, "precondition: the dialog is up")
                let page = try #require(WindowRenders.page(in: window))
                #expect(window.makeFirstResponder(page))
                page.insertText("Typed on the page.", replacementRange: NSRange(location: 0, length: 0))
                let field = try #require(
                    subviewTree(of: sheet.contentView).compactMap { $0 as? AdmittingTextField }.first)
                #expect(sheet.makeFirstResponder(field))
                try #require(field.editor).insertText(
                    "draft", replacementRange: NSRange(location: 0, length: 0))
            } capture: { window in
                let sheet = try #require(window.attachedSheet)
                let page = try #require(WindowRenders.page(in: window))
                #expect(window.firstResponder === page, "precondition: the page is still the window's")
                #expect(page.undoManager === book.pageUndo(for: scene))
                #expect(page.undoManager?.canUndo == true, "precondition: the page has an undo")
                let editor = try #require(
                    sheet.firstResponder as? AdmittingTextView, "the tag field is editing")
                #expect(filing.draft?.pendingTag == "draft", "precondition: the tag field took the typing")
                router.attach(to: window)
                #expect(router.manager === editor.undoManager, "Undo goes to the dialog's field")
                #expect(router.manager !== book.pageUndo(for: scene))
                let before = book.book.scene(scene)?.body
                router.undo()
                return (before, book.book.scene(scene)?.body)
            }
            #expect(before?.map(\.text) == ["Typed on the page."], "precondition: the page took the typing")
            #expect(after == before, "the scene is unchanged")
            #expect(filing.draft?.pendingTag == "", "the dialog's typing was undone")
            filing.cancel()
            #expect(await store.closeBook() == .left)
        }
    }
}

/// A draft a test's dialog edits.
@MainActor
private final class DraftBox {
    var draft: FilingDraft

    init(_ draft: FilingDraft) {
        self.draft = draft
    }
}
