import AppKit
import SceneItCore
import SwiftUI
import Testing

@testable import SceneIt

/// The download website's screenshots (`site/images/`), at 2×, into a `site/` subfolder: the
/// Scenes sheet with the Boneyard, comments on the page and in the panel, search across the File
/// Cabinet's filed copies, a page printed with comments, and read aloud. One book throughout: the
/// Scenes sheet's sample with a longer, commented ferry scene. Nothing is heard: the synthesizer
/// is a `RecordedSpeech`.
extension WindowRenders {
    @Test func site() async throws {
        let output = try #require(renderFolder).appending(path: "site", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let book = Self.siteBook()

        try await withSampleBook(book) { store, book, preferences in
            let view = preferences.scenesView
            defer { preferences.showScenes(as: view) }
            preferences.showScenes(as: .cards)
            try #require(!book.book.boneyard.isEmpty, "precondition: the tray holds cut scenes")
            try Self.writeSite(
                try await Self.render(Self.window(book, store, preferences, .scenes), in: KeyWindow.self),
                "scenes", to: output)

            preferences.reveal(.comments)
            try Self.writeSite(
                try await Self.render(Self.window(book, store, preferences, .page), in: KeyWindow.self) {
                    try Self.clickComment(on: "letter", in: $0)
                },
                "comments", to: output)

            preferences.setRightPanel(.closed)
            defer { preferences.setRightPanel(.open) }
            let speech = RecordedSpeech()
            let readAloud = ReadAloud(preferences: preferences, speech: speech)
            let reading = try await Self.render(
                Self.window(book, store, preferences, .page, readAloud: readAloud), in: KeyWindow.self
            ) { window in
                let page = try #require(Self.page(in: window))
                #expect(window.makeFirstResponder(page))
                let text = page.string as NSString
                let start = text.range(of: "Halfway across")
                let end = text.range(of: "had dropped.")
                try #require(
                    start.location != NSNotFound && end.location != NSNotFound,
                    "precondition: the third and fourth paragraphs")
                page.setSelectedRange(
                    NSRange(location: start.location, length: NSMaxRange(end) - start.location))
                readAloud.press()
                let utterance = try #require(speech.requests.last?.text) as NSString
                speech.report(.willSpeak(utterance.range(of: "bench")))
            }
            #expect(readAloud.control == .stop, "precondition: reading")
            try Self.writeSite(reading, "read-aloud", to: output)
            readAloud.stop()
        }

        try await withFiledSample(Self.mockupCopies(), of: book) { store, book, preferences in
            let model = SearchSheetModel(book: book)
            let search = BookWindow(
                book: book, store: store, preferences: preferences,
                formatting: EditorFormatting(preferences: preferences), mode: .constant(.search),
                search: model)
            try Self.writeSite(
                try await Self.render(search) { _ in
                    model.scope = .fileCabinet
                    model.text = "letter"
                    await model.settle()
                },
                "cabinet", to: output)
        }

        let printed = try PrintTests.pdf(
            PrintTests.view(book, layout: .withComments), PrintTests.printInfo(.withComments))
        try Self.png(try Self.bitmap(of: try #require(printed.page(at: 0)), scale: 2))
            .write(to: output.appending(path: "print@2x.png"))
    }

    private static func window(
        _ book: AppOpenBook, _ store: AppBookStore, _ preferences: AppPreferences, _ mode: WindowMode,
        readAloud: ReadAloud? = nil
    ) -> BookWindow {
        BookWindow(
            book: book, store: store, preferences: preferences,
            formatting: EditorFormatting(preferences: preferences), mode: .constant(mode),
            readAloud: readAloud)
    }

    /// A plain click on `words` on the page, as `ManuscriptTextView.mouseDown` hands it on.
    private static func clickComment(on words: String, in window: NSWindow) throws {
        let page = try #require(page(in: window))
        let found = (page.string as NSString).range(of: words)
        try #require(found.location != NSNotFound, "precondition: the words are on the page")
        window.makeFirstResponder(page)
        page.setSelectedRange(NSRange(location: found.location + 2, length: 0))
        page.editor?.clickedComments(at: found.location + 2)
    }

    private static func writeSite(_ renders: Renders, _ name: String, to output: URL) throws {
        try png(renders.double).write(to: output.appending(path: "\(name)@2x.png"))
    }

    /// The Scenes sheet's sample, its ferry scene a page long with nine comments, two of them
    /// overlapping, and text colors and highlights.
    static func siteBook() -> Book {
        var book = scenesSampleBook()
        let created = Timestamp("2026-11-03T10:15:00-08:00")!
        let notes: [(PaletteColor, String)] = [
            (.red, "Check the ferry schedule for the 1950s."),
            (.red, "Packed what? One case, or two?"),
            (.blue, "How old was she when she left? Keep this consistent with chapter 3."),
            (.green, "Echo this in the last scene."),
            (.gray, "Which language? Decide before the market scene."),
            (.purple, "Too early for this reveal?"),
            (.pink, "Too neat. Let her see the letter go over the side instead?"),
            (.blue, "Lovely image; keep."),
            (.purple, "Does the water need to be looking for something? Maybe cut."),
        ]
        let comments = notes.enumerated().map { index, note in
            SceneItCore::Comment(
                id: CommentID(rawValue: "site\(index)"), color: note.0, text: note.1, created: created)
        }
        func on(_ indices: Int...) -> Set<CommentID> { Set(indices.map { comments[$0].id }) }
        book.scenes[0].comments = comments
        book.scenes[0].body = [
            [
                Run("The ferry left at dawn", comments: on(0)),
                Run(", and Mara watched the "), Run("harbor lights", color: .blue),
                Run(" go out one by one behind her."),
            ],
            [
                Run("She had "), Run("packed", comments: on(1)),
                Run(" in the dark, by feel, the way she used to as a "), Run("girl", comments: on(2)),
                Run(" when the house was asleep and leaving still seemed like a "),
                Run("game", styles: [.italic], comments: on(3)), Run("."),
            ],
            [
                Run("Halfway across, the engine coughed and the deckhand "), Run("swore", comments: on(4)),
                Run(" at it in a language she half remembered. He found the "),
                Run("letter", color: .purple, comments: on(5)),
                Run(" under the bench an hour later, but by then she was "),
                Run("already ashore", highlight: .green, comments: on(6)), Run("."),
            ],
            [
                Run(
                    "Nobody had told her how cold the water would look from the rail -- not blue at all, but the "
                ),
                Run("grey of an old knife, ", comments: on(7)),
                Run("turning and turning", comments: on(7, 8)),
                Run(" under the hull", comments: on(8)),
                Run(" as if it were looking for something it had dropped."),
            ],
            [
                Run(
                    "A boy with a basket of eggs sat across from her and stared, the way island children always "
                        + "stared at anyone who arrived with more than one bag. She smiled at him; he did not "
                        + "smile back.")
            ],
            [
                Run(
                    "\"First time over?\" the deckhand asked, coiling a rope that did not need coiling. She told "
                        + "him no, it was not her first time, and then "),
                Run("regretted", styles: [.bold]), Run(" saying anything at all."),
            ],
            [
                Run(
                    "The island came up out of the fog all at once: the chapel, the harbor wall, the long white "
                        + "house on the hill where the lamp had burned every night of her childhood.")
            ],
        ]
        return book
    }
}
