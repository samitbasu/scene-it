import AppKit
import SceneItCore
import SwiftUI

/// File → New Book…, Open Book…, Review Book…, Close Book, Save, Make Editable…, File a Copy… and Export as
/// SceneIt…, in place of SwiftUI's New Window, Close and Save. New, Open and Review are offered only on
/// the start screen, and Close Book returns there (ADR 0038); from any window but the main one,
/// ⌘W closes that window.
struct BookCommands: Commands {
    let books: BookController
    @FocusedValue(\.filingFlow) private var filing
    @FocusedValue(\.exportFlow) private var export

    var body: some Commands {
        let choosing = books.store.isChoosing
        CommandGroup(replacing: .newItem) {
            Button(StoreWording.newBookMenuItem) { Task { await books.newBook() } }
                .keyboardShortcut("n")
                .disabled(!choosing)
            Button(StoreWording.openBookMenuItem) { Task { await books.openBook() } }
                .keyboardShortcut("o")
                .disabled(!choosing)
            Button(ReviewWording.menuItem) { Task { await books.reviewBook() } }
                .disabled(!choosing)
        }
        CommandGroup(replacing: .saveItem) {
            Button(books.closeItemTitle) { books.press(.menu(keyWindow: NSApp.keyWindow)) }
                .keyboardShortcut("w")
            Button(StoreWording.saveMenuItem) { books.store.saveNow() }
                .keyboardShortcut("s")
                .disabled(choosing)
            Button(ErrorsWording.makeEditableItem) { Task { await books.store.confirmMakeEditable() } }
                .disabled(!books.store.canMakeEditable)
            Button(ArchiveWording.menuItem) { filing?.begin() }
                .disabled(filing?.canBegin(in: books.store) != true || export?.choice != nil)
            Button(ExportWording.menuItem) { export?.begin() }
                .disabled(export?.canBegin(in: books.store) != true || filing?.draft != nil)
        }
    }
}
