import AppKit
import SceneItCore
import SwiftUI

/// The one main window (ADR 0038): the start screen, or the open book. Its close button quits
/// Scene It (#130); File → Close Book returns to the start screen.
struct MainWindow: View {
    let books: BookController

    var body: some View {
        Group {
            switch books.store.session {
            case .choosing:
                StartView(books: books)
            case .open(let book), .closing(let book):
                // A new identity per `OpenBook`, so window state (an open sheet, the editors,
                // the undo router) never outlives the one it was made for when the book is
                // read again (Open Anyway, Open Other Version).
                OpenBookWindow(
                    book: book, store: books.store, preferences: books.preferences,
                    formatting: books.formatting, mainChrome: books.mainWindowChrome,
                    exportDestination: { [books] in books.exportDestination }
                )
                .id(book.instanceID)
            }
        }
        .frame(minWidth: WindowMetrics.minimumSize.width, minHeight: WindowMetrics.minimumSize.height)
        .background(MainWindowCloseButton(books: books))
    }
}

/// Points the window's close button at `BookController.press(.closeButton)` (ADR 0038): it
/// quits Scene It, through Quit's own path, so it asks what Quit asks and Cancel leaves the
/// window and its book as they were (#130).
struct MainWindowCloseButton: NSViewRepresentable {
    let books: BookController

    func makeNSView(context: Context) -> Router {
        Router(books: books)
    }

    func updateNSView(_ router: Router, context: Context) {
        router.route()
    }

    final class Router: NSView {
        let books: BookController

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
            books.press(.closeButton)
        }
    }
}

/// Owns the window's mode for one open book.
private struct OpenBookWindow: View {
    let book: AppOpenBook
    let store: AppBookStore
    let preferences: AppPreferences
    let formatting: EditorFormatting
    let mainChrome: MainWindowChrome
    let exportDestination: () -> ExportDestination
    @State private var mode = WindowMode.page
    @State private var chrome = WindowChrome()

    var body: some View {
        BookWindow(
            book: book, store: store, preferences: preferences, formatting: formatting, mode: $mode,
            export: ExportFlow(book: book, destination: exportDestination), chrome: chrome
        )
        .onAppear { mainChrome.show(chrome) }
        .onDisappear { mainChrome.gone(chrome) }
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
