import SceneItCore
import SwiftUI

// TEMPORARY SCAFFOLDING (#11). Just enough window to drive the BookStore end to end: a start
// state, the scene list, a plain-text editor and the status text. No look has been chosen.
// #13 replaces it with the real window skeleton, and #15 with the real editor.

struct ContentView: View {
    let books: BookController

    var body: some View {
        Group {
            if let book = books.store.current {
                TemporaryBookView(book: book)
            } else {
                TemporaryStartView(books: books)
            }
        }
        .frame(minWidth: 800, minHeight: 600)
        .padding()
    }
}

private struct TemporaryStartView: View {
    let books: BookController

    var body: some View {
        VStack(alignment: .leading) {
            Text(StoreWording.noBookOpen)
            Button(StoreWording.newBookMenuItem) { Task { await books.newBook() } }
            Button(StoreWording.openBookMenuItem) { Task { await books.openBook() } }
            Text(StoreWording.recentBooks)
            ForEach(books.store.recentBooks, id: \.self) { url in
                Button(url.deletingPathExtension().lastPathComponent) { Task { await books.store.open(url) } }
            }
            Spacer()
        }
    }
}

private struct TemporaryBookView: View {
    let book: OpenBook<ContinuousClock>

    var body: some View {
        VStack(alignment: .leading) {
            Text(book.book.title)
            HStack(alignment: .top) {
                VStack(alignment: .leading) {
                    List(
                        book.book.scenes,
                        selection: Binding(get: { book.openScene }, set: { book.select($0) })
                    ) {
                        Text($0.title.text.isEmpty ? StoreWording.untitledScene : $0.title.text)
                    }
                    Button(StoreWording.addScene) { book.addScene(after: book.openScene) }
                        .disabled(!book.isEditable)
                }
                .frame(width: 220)
                if let scene = book.book.scenes.first(where: { $0.id == book.openScene }) {
                    TemporarySceneEditor(book: book, scene: scene)
                } else {
                    Spacer()
                }
            }
            Text(StoreWording.status(book.status))
        }
        .navigationTitle(book.book.title)
    }
}

private struct TemporarySceneEditor: View {
    let book: OpenBook<ContinuousClock>
    let scene: BookScene

    var body: some View {
        VStack(alignment: .leading) {
            TextField(
                StoreWording.sceneTitlePlaceholder,
                text: Binding(
                    get: { scene.title.text },
                    set: { book.setTitle(of: scene.id, to: SceneTitle(pasted: $0)) })
            )
            .disabled(!book.isEditable)
            if PlainBody.isPlain(scene) {
                TextEditor(
                    text: Binding(
                        get: { PlainBody.text(scene.body) },
                        set: { book.replaceBody(of: scene.id, with: PlainBody.paragraphs($0)) })
                )
                .disabled(!book.isEditable)
            } else {
                Text(StoreWording.formattedSceneNotEditable)
                Spacer()
            }
        }
    }
}

/// A scene body as plain text, one line per paragraph. Only for bodies with no formatting
/// and no comments, which this conversion would silently drop.
enum PlainBody {
    static func isPlain(_ scene: BookScene) -> Bool {
        scene.comments.isEmpty
            && scene.body.allSatisfy { paragraph in paragraph.runs.allSatisfy { $0 == Run($0.text) } }
    }

    static func text(_ body: [Paragraph]) -> String {
        body.map(\.text).joined(separator: "\n")
    }

    static func paragraphs(_ text: String) -> [Paragraph] {
        guard !text.isEmpty else { return [] }
        return text.filter { !$0.isObjectReplacement }
            .split(omittingEmptySubsequences: false, whereSeparator: \.isLineBreak)
            .map { $0.isEmpty ? [] : [Run(String($0))] }
    }
}
