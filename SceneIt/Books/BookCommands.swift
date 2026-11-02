import SceneItCore
import SwiftUI

/// File → New Book…, Open Book… and Save, in place of SwiftUI's New Window and Save.
struct BookCommands: Commands {
    let books: BookController

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
        }
    }
}
