import SceneItCore
import SwiftUI

/// File → New Book…, Open Book…, Close Book, Save, Make Editable… and File a Copy…, in place of
/// SwiftUI's New Window, Close and Save. New and Open are offered only on the start screen, and
/// Close Book returns there (ADR 0038); from any window but the main one, ⌘W closes that window.
struct BookCommands: Commands {
    let books: BookController
    @FocusedValue(\.filingFlow) private var filing

    var body: some Commands {
        let choosing = books.store.isChoosing
        CommandGroup(replacing: .newItem) {
            Button(StoreWording.newBookMenuItem) { Task { await books.newBook() } }
                .keyboardShortcut("n")
                .disabled(!choosing)
            Button(StoreWording.openBookMenuItem) { Task { await books.openBook() } }
                .keyboardShortcut("o")
                .disabled(!choosing)
        }
        CommandGroup(replacing: .saveItem) {
            Button(books.closeItemTitle) { Task { await books.closeFromMenu() } }
                .keyboardShortcut("w")
                .disabled(!books.isCloseItemEnabled)
            Button(StoreWording.saveMenuItem) { books.store.saveNow() }
                .keyboardShortcut("s")
            Button(ErrorsWording.makeEditableItem) { Task { await books.store.confirmMakeEditable() } }
                .disabled(books.store.current?.canBeMadeEditable != true)
            Button(ArchiveWording.menuItem) { filing?.begin() }
                .disabled(filing == nil || books.store.current?.isEditable != true || filing?.draft != nil)
        }
    }
}
