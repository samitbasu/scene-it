import SceneItCore
import SwiftUI

/// The one main window (ADR 0021): the open book, or the start state when none is open.
struct MainWindow: View {
    let books: BookController

    var body: some View {
        Group {
            if let book = books.store.current {
                // A new identity per book, so window state such as an open sheet never
                // outlives the book it was opened over.
                BookWindow(book: book, preferences: books.preferences)
                    .id(ObjectIdentifier(book))
            } else {
                StartView(books: books)
            }
        }
        .frame(minWidth: 1040, minHeight: 640)
    }
}

struct StartView: View {
    let books: BookController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(WindowWording.noBookOpen)
                .font(.title2)
            HStack {
                Button(StoreWording.newBookMenuItem) { Task { await books.newBook() } }
                Button(StoreWording.openBookMenuItem) { Task { await books.openBook() } }
            }
            Text(WindowWording.recentBooks)
                .font(.headline)
                .padding(.top, 8)
            if books.store.recentBooks.isEmpty {
                Text(WindowWording.noRecentBooks)
                    .foregroundStyle(.secondary)
            }
            ForEach(books.store.recentBooks, id: \.self) { url in
                Button(StoreWording.bookName(url)) { Task { await books.store.open(url) } }
                    .buttonStyle(.link)
                    .help(url.path(percentEncoded: false))
            }
        }
        .frame(maxWidth: 420, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(StoreWording.windowTitle)
    }
}
