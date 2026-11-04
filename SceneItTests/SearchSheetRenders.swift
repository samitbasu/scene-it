import AppKit
import SceneItCore
import SwiftUI
import Testing

@testable import SceneIt

/// The Search sheet (#31, phase 1): its states over the window at 1× and 2× beside mockup 10,
/// and each open choice's candidates side by side.
extension WindowRenders {
    static let searchMockup = "10-search-whole-book.png"

    /// The sample book with what the mockup's search finds: notes and a comment in the first
    /// scene, tags, and the letter in a Boneyard scene too.
    static func searchSampleBook() -> Book {
        var book = sampleBook()
        var ids = IDGenerator<SystemRandomNumberGenerator>.system
        let comment = Comment(
            id: ids.commentID(), color: .purple, text: "Is the letter in her coat, or in the bag?",
            created: Timestamp(.now, in: .current))
        book.scenes[0].body[2] = [
            Run(
                "Halfway across, the engine coughed and the deckhand swore at it in a language she half "
                    + "remembered. He found the "),
            Run("letter", comments: [comment.id]),
            Run(" under the bench an hour later, but by then she was already ashore."),
        ]
        book.scenes[0].comments = [comment]
        book.scenes[0].notes = [
            [
                Run(
                    "Why does she leave at dawn in March? Who kept the mother's letter all these years? "
                        + "Decide before scene 3. Mara should notice the handwriting.")
            ]
        ]
        book.scenes[0].tags = ["mara", "departure"]
        book.scenes[2].tags = ["letter", "mother"]
        book.boneyard[1].body.append([
            Run("She burned the letter on the beach and walked home along the tide line.")
        ])
        return book
    }

    private func withSearchSheet(
        _ body: (AppBookStore, AppOpenBook, AppPreferences, SearchSheetModel) async throws -> Void
    ) async throws {
        try await withSampleBook(Self.searchSampleBook()) { store, book, preferences in
            try await body(store, book, preferences, SearchSheetModel(book: book))
        }
    }

    private static func sheet(
        _ store: AppBookStore, _ book: AppOpenBook, _ preferences: AppPreferences, _ model: SearchSheetModel,
        look: SearchSheetLook = .recommended
    ) -> some View {
        BookWindow(
            book: book, store: store, preferences: preferences,
            formatting: EditorFormatting(preferences: preferences), mode: .constant(.search), search: model
        )
        .environment(\.searchSheetLook, look)
    }

    /// Renders the sheet after `prepare` sets up the model, once its search is complete.
    private static func renderSheet(
        _ store: AppBookStore, _ book: AppOpenBook, _ preferences: AppPreferences, _ model: SearchSheetModel,
        look: SearchSheetLook = .recommended, _ prepare: @escaping (SearchSheetModel) -> Void
    ) async throws -> Renders {
        try await render(sheet(store, book, preferences, model, look: look)) { _ in prepare(model) }
    }

    @Test func searchSheet() async throws {
        let output = try #require(renderFolder).appending(path: "search", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try await withSearchSheet { store, book, preferences, model in
            @MainActor func state(
                _ name: String, _ caption: String, _ prepare: @escaping (SearchSheetModel) -> Void
            )
                async throws
            {
                let renders = try await Self.renderSheet(store, book, preferences, model, prepare)
                await model.settle()
                try Self.write(renders, name: name, caption: caption, to: output, beside: Self.searchMockup)
            }
            try await state("search-prompt", "Nothing typed yet") { $0.text = "" }
            try await state("search-exact", "\"letter\", Search tags on, Whole book") {
                $0.set(.searchTags, .on)
                $0.text = "letter"
            }
            try #require(Self.listing(model)?.quality == .exact, "precondition: exact matches")
            try await state("search-exact-expanded", "\"letter\", the first scene's +N more opened") {
                $0.text = "letter"
                if let first = Self.listing($0)?.scenes.first { $0.toggleExpanded(first) }
            }
            try await state("search-near", "\"found the ring\": no exact matches, the best 20 scenes") {
                $0.set(.searchTags, .off)
                $0.text = "found the ring"
            }
            let near = try #require(Self.listing(model))
            #expect(near.quality == .near && near.hiddenSceneCount > 0, "precondition: capped near matches")
            let end = try await Self.render(Self.sheet(store, book, preferences, model)) { window in
                for scroll in subviewTree(of: window.contentView).compactMap({ $0 as? NSScrollView })
                where !(scroll is DeskView) {
                    scroll.documentView?.scroll(NSPoint(x: 0, y: scroll.documentView?.bounds.maxY ?? 0))
                }
            }
            try Self.write(
                end, name: "search-near-end", caption: "\"found the ring\", scrolled to the end: Show all",
                to: output, beside: Self.searchMockup)
            try await state("search-near-all", "\"found the ring\" after Show all") {
                $0.text = "found the ring"
                $0.showAllNearMatches()
            }
            try await state("search-no-results", "\"zebra\": no matches") { $0.text = "zebra" }
            try await state("search-no-words", "\"--\": no words to search for") { $0.text = "--" }
            try await state("search-this-scene", "\"the\" in This scene (1. The ferry)") {
                $0.scope = .thisScene
                $0.text = "the"
            }
            try #require(Self.listing(model)?.scenes.count == 1, "precondition: one scene")
            try await state("search-long", "\"the\" in the Whole book: a long list") {
                $0.scope = .wholeBook
                $0.text = "the"
            }
            try #require((Self.listing(model)?.sceneCount ?? 0) > 20, "precondition: more scenes than fit")
        }
    }

    private static func listing(_ model: SearchSheetModel) -> SearchListing? {
        if case .results(let listing, .current) = model.state { listing } else { nil }
    }

    // MARK: Candidates

    @Test func searchSheetCandidates() async throws {
        let output = try #require(renderFolder).appending(path: "search", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try await withSearchSheet { store, book, preferences, model in
            @MainActor func compare<Choice>(
                _ name: String, _ choices: [(Choice, String)], crop height: CGFloat,
                look: (Choice) -> SearchSheetLook, _ prepare: @escaping (SearchSheetModel) -> Void
            ) async throws {
                var renders: [(Renders, String)] = []
                for (choice, caption) in choices {
                    renders.append(
                        (
                            try await Self.renderSheet(
                                store, book, preferences, model, look: look(choice), prepare), caption
                        ))
                    await model.settle()
                }
                for scale in [1, 2] {
                    try Self.png(try Self.stack(renders.map { ($0.0, $0.1) }, scale: scale, height: height))
                        .write(to: output.appending(path: "\(name)@\(scale)x.png"))
                }
            }
            let exact: (SearchSheetModel) -> Void = {
                $0.set(.searchTags, .on)
                $0.text = "letter"
            }
            try await compare(
                "candidates-options",
                [
                    (SearchSheetLook.Options.oneRow, "A. One row, as the mockup (recommended)"),
                    (.twoRows, "B. Two rows: the checkboxes under the field"),
                    (.oneRowWithCabinet, "C. One row, with File Cabinet shown but disabled until #34"),
                ], crop: 260, look: { SearchSheetLook(options: $0) }, exact)
            try await compare(
                "candidates-rows",
                [
                    (
                        SearchSheetLook.Rows.bestThenMore,
                        "A. A card per scene: its best hit, then +N more (recommended)"
                    ),
                    (.firstThreeThenMore, "B. A card per scene: its best three hits, then +N more"),
                    (.compact, "C. No cards: one line per scene"),
                ], crop: 560, look: { SearchSheetLook(rows: $0) }
            ) {
                $0.set(.searchTags, .on)
                $0.text = "the"
            }
            try await compare(
                "candidates-match",
                [
                    (SearchSheetLook.MatchMark.yellow, "A. Yellow marker, as the mockup (recommended)"),
                    (.yellowBold, "B. Yellow marker, bold"),
                    (.accentTint, "C. The accent color's tint"),
                ], crop: 330, look: { SearchSheetLook(match: $0) }, exact)
            try await compare(
                "candidates-differs",
                [
                    (SearchSheetLook.DiffersMark.orangeUnderline, "A. Solid orange underline (recommended)"),
                    (.dottedRed, "B. Dotted red underline"),
                    (.grayDashed, "C. Gray marker with a dashed underline"),
                ], crop: 330, look: { SearchSheetLook(differs: $0) }
            ) {
                $0.set(.searchTags, .off)
                $0.text = "found the ring"
            }
        }
    }

    /// The top `height` points of each render at `scale`, one under another, each under its caption.
    private static func stack(_ renders: [(Renders, String)], scale: Int, height: CGFloat) throws
        -> NSBitmapImageRep
    {
        let header: CGFloat = 34
        let gap: CGFloat = 16
        let width = windowSize.width
        let size = CGSize(
            width: width,
            height: CGFloat(renders.count) * (header + height) + CGFloat(renders.count - 1) * gap)
        let rep = blankBitmap(width: Int(size.width) * scale, height: Int(size.height) * scale)
        rep.size = size
        let context = try #require(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        NSColor(white: 0.8, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 18, weight: .medium)
        ]
        var top = size.height
        for (renders, caption) in renders {
            let source = scale == 1 ? renders.single : renders.double
            let image = try #require(source.cgImage)
            let crop = try #require(
                image.cropping(
                    to: CGRect(x: 0, y: 0, width: CGFloat(image.width), height: height * CGFloat(scale))))
            NSAttributedString(string: caption, attributes: attributes).draw(at: NSPoint(x: 8, y: top - 26))
            top -= header + height
            NSImage(cgImage: crop, size: NSSize(width: width, height: height))
                .draw(in: NSRect(x: 0, y: top, width: width, height: height))
            top -= gap
        }
        return rep
    }
}
