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
                OpenBookWindow(book: book, preferences: books.preferences)
                    .id(book.layout.root)
            } else {
                StartView(books: books)
            }
        }
        .frame(minWidth: WindowMetrics.minimumSize.width, minHeight: WindowMetrics.minimumSize.height)
    }
}

/// Owns the window's mode for one open book.
private struct OpenBookWindow: View {
    let book: AppOpenBook
    let preferences: AppPreferences
    @State private var mode = WindowMode.page

    var body: some View {
        BookWindow(book: book, preferences: preferences, mode: $mode)
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
