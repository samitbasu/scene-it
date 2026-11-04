import AppKit
import SceneItCore
import SwiftUI
import Testing

@testable import SceneIt

/// File a Copy in the app (PLAN §7.1), through a test-host store, the dialog's tag field and
/// the action its File copy button runs. Each test has its own store: the app's own belongs to
/// `BookStoreIntegrationTests`, which may run at the same time.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct FileACopyTests {
    @Test func theFileMenuHasFileACopy() {
        #expect(menuItem(titled: ArchiveWording.menuItem, in: NSApp.mainMenu) != nil)
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

            let flow = FilingFlow()
            let today = try #require(CalendarDay(year: 2026, month: 11, day: 3))
            flow.begin(today: today)
            let field = TagTextField.Coordinator(
                draft: Binding(get: { flow.draft! }, set: { flow.draft = $0 }))
            let editor = NSTextView()
            let control = NSTextField()
            for tag in ["draft 4", "oops"] {
                editor.string = tag
                #expect(
                    field.control(
                        control, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
                #expect(editor.string.isEmpty, "Return empties the field")
            }
            #expect(
                field.control(
                    control, textView: editor, doCommandBy: #selector(NSResponder.deleteBackward(_:))))
            #expect(flow.draft?.tags == ["draft 4"], "⌫ in the empty field removed the last chip")
            editor.string = "x"
            #expect(
                !field.control(
                    control, textView: editor, doCommandBy: #selector(NSResponder.deleteBackward(_:))))
            flow.draft?.note = "Before the ending rewrite"

            let result = await flow.confirm(in: store)

            guard case .filed(let outcome)? = result else {
                Issue.record("expected a filed copy, got \(String(describing: result))")
                return
            }
            #expect(outcome.isComplete)
            #expect(flow.draft == nil, "the dialog closed")
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

    @Test func aFilingThatFailsKeepsTheDialogOpenWithWhatWasTyped() async throws {
        try await withTemporaryFolder { folder in
            let books = BookController(role: .testHost)
            let store = books.store
            let url = folder.appending(path: "Failing 32.sceneit", directoryHint: .isDirectory)
            #expect(await store.create(at: url) == .created)
            let layout = PackageLayout(root: url)
            try FileManager.default.removeItem(at: layout.archive)
            try Data("not a folder".utf8).write(to: layout.archive)
            let flow = FilingFlow()
            flow.begin()
            flow.draft?.pendingTag = "draft 4"
            flow.draft?.commitPendingTag()
            flow.draft?.note = "Keep me"
            let typed = flow.draft

            let result = await flow.confirm(in: store)

            #expect(result == .failed(.archiveNotAFolder))
            #expect(flow.draft == typed, "the dialog is still up, as the writer left it")
            #expect(!flow.isFiling)
            #expect(flow.toast == nil)
            #expect((books.prompts as? HeadlessPrompts)?.takeTitles() == ["Scene It couldn't file a copy."])
            #expect(await store.closeBook() == .left)
        }
    }

    /// The dialog's tags and note go through the character policy as the editors do (ADR
    /// 0028): what's typed or pasted is transliterated to ASCII as it arrives.
    @Test func theTagAndNoteFieldsAdmitWhatsTypedThroughTheCharacterPolicy() throws {
        let typed = "caf\u{E9} \u{2014} \u{201C}na\u{EF}ve\u{201D}"
        #expect(
            CharacterPolicy.admittedLine(typed) == "cafe -- \"naive\"",
            "precondition: the policy transliterates")
        for (editor, admit) in [
            (TagField.Cell().editor, CharacterPolicy.admittedLine),
            (NoteTextView.editor(), CharacterPolicy.admittedInput),
        ] {
            #expect(editor.inputContext == nil, "no input method")
            editor.insertText(typed, replacementRange: NSRange(location: 0, length: 0))
            #expect(editor.string == admit(typed))
            let isASCII = editor.string.unicodeScalars.allSatisfy { $0.isASCII }
            #expect(isASCII)
            #expect(
                editor.selectedRange() == NSRange(location: (editor.string as NSString).length, length: 0))
        }
    }

    @Test func aReadOnlyBookHasNoFileACopy() async throws {
        try await withTemporaryFolder { folder in
            let books = BookController(role: .testHost)
            let store = books.store
            let url = folder.appending(path: "Held 32.sceneit", directoryHint: .isDirectory)
            let holder = try BookPackage.create(at: url, title: "Held")
            #expect(await store.open(url) == .openedReadOnly(.openElsewhere))
            let flow = FilingFlow()
            flow.begin()
            #expect(await flow.confirm(in: store) == .unavailable)
            #expect(store.current?.isEditable == false)
            #expect(await store.closeBook() == .left)
            _ = (books.prompts as? HeadlessPrompts)?.takeTitles()
            _ = holder
        }
    }
}
