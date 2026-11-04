import AppKit
import SceneItCore
import SwiftUI
import Testing

@testable import SceneIt

/// The Search sheet as the owner chose it (#31): its states over the window at 1× and 2× beside
/// mockup 10.
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
        _ store: AppBookStore, _ book: AppOpenBook, _ preferences: AppPreferences, _ model: SearchSheetModel
    ) -> some View {
        BookWindow(
            book: book, store: store, preferences: preferences,
            formatting: EditorFormatting(preferences: preferences), mode: .constant(.search), search: model)
    }

    /// Renders the sheet once `prepare` has set up the model and the search it started is
    /// complete (`settle`), so no render catches a search in progress.
    private static func renderSheet(
        _ store: AppBookStore, _ book: AppOpenBook, _ preferences: AppPreferences, _ model: SearchSheetModel,
        _ prepare: @escaping (SearchSheetModel) async -> Void
    ) async throws -> Renders {
        try await render(sheet(store, book, preferences, model)) { _ in
            await prepare(model)
            await model.settle()
        }
    }

    @Test func searchSheet() async throws {
        let output = try #require(renderFolder).appending(path: "search", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try await withSearchSheet { store, book, preferences, model in
            @MainActor func state(
                _ name: String, _ caption: String, _ prepare: @escaping (SearchSheetModel) async -> Void
            )
                async throws
            {
                let renders = try await Self.renderSheet(store, book, preferences, model, prepare)
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
                await $0.settle()
                if let first = Self.listing($0)?.scenes.first { $0.toggleExpanded(first) }
            }
            try await state("search-near", "\"found the ring\": no exact matches, the best 20 scenes") {
                $0.set(.searchTags, .off)
                $0.text = "found the ring"
            }
            let near = try #require(Self.listing(model))
            #expect(near.quality == .near && near.hiddenSceneCount > 0, "precondition: capped near matches")
            let end = try await Self.render(Self.sheet(store, book, preferences, model)) { window in
                await model.settle()
                window.contentView?.layoutSubtreeIfNeeded()
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
}
