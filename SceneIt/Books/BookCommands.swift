import SceneItCore
import SwiftUI

/// File → New Book…, Open Book…, Save, Make Editable… and File a Copy…, in place of SwiftUI's
/// New Window and Save.
struct BookCommands: Commands {
    let books: BookController
    @FocusedValue(\.filingFlow) private var filing

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(StoreWording.newBookMenuItem) { Task { await books.newBook() } }
                .keyboardShortcut("n")
            Button(StoreWording.openBookMenuItem) { Task { await books.openBook() } }
                .keyboardShortcut("o")
        }
        CommandGroup(replacing: .saveItem) {
            Button(StoreWording.saveMenuItem) { books.store.saveNow() }
                .keyboardShortcut("s")
            Button(ErrorsWording.makeEditableItem) { Task { await books.store.confirmMakeEditable() } }
                .disabled(books.store.current?.canBeMadeEditable != true)
            Button(ArchiveWording.menuItem) { filing?.begin() }
                .disabled(filing == nil || books.store.current?.isEditable != true || filing?.draft != nil)
        }
    }
}
