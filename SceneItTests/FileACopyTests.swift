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
