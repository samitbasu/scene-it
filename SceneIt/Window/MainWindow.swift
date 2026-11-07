import AppKit
import SceneItCore
import SwiftUI

/// The one main window (ADR 0038): the start state until the process has its book, then the
/// book. Closing it is Quit.
struct MainWindow: View {
    let books: BookController

    var body: some View {
        Group {
            switch books.store.session {
            case .choosing:
                StartView(books: books)
            case .open(let book):
                // A new identity per `OpenBook`, so window state (an open sheet, the editors,
                // the undo router) never outlives the one it was made for when the book is
                // read again (Open Anyway, Open Other Version).
                OpenBookWindow(
                    book: book, store: books.store, preferences: books.preferences,
                    formatting: books.formatting
                )
                .id(book.instanceID)
            case .ended:
                Color.clear
            }
        }
        .frame(minWidth: WindowMetrics.minimumSize.width, minHeight: WindowMetrics.minimumSize.height)
        .background(CloseButtonQuits(books: books))
    }
}

/// Points the window's close button at Close Book, which quits (ADR 0038), so closing the
/// window asks what Quit asks and Cancel leaves the window and its book open.
struct CloseButtonQuits: NSViewRepresentable {
    let books: BookController

    func makeNSView(context: Context) -> Router {
        Router(books: books)
    }

    func updateNSView(_ router: Router, context: Context) {
        router.route()
    }

    final class Router: NSView {
        private let books: BookController

        init(books: BookController) {
            self.books = books
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("not loaded from a nib")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            route()
        }

        func route() {
            guard let button = window?.standardWindowButton(.closeButton) else { return }
            button.target = self
            button.action = #selector(closeClicked(_:))
        }

        @objc private func closeClicked(_ sender: Any?) {
            books.closeBook()
        }
    }
}

/// Owns the window's mode for one open book.
private struct OpenBookWindow: View {
    let book: AppOpenBook
    let store: AppBookStore
    let preferences: AppPreferences
    let formatting: EditorFormatting
    @State private var mode = WindowMode.page

    var body: some View {
        BookWindow(book: book, store: store, preferences: preferences, formatting: formatting, mode: $mode)
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
