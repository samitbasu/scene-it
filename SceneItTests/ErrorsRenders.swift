import AppKit
import SceneItCore
import SwiftUI
import Testing

@testable import SceneIt

// TEMPORARY (#63, #67): renders the Errors tab and read-only banner candidates for the owner's
// pick, each beside the window as it is without them. Goes once the owner has chosen.

@Suite(.serialized, .enabled(if: renderFolder != nil), .timeLimit(.minutes(5)))
struct ErrorsRenders {
    typealias Renders = WindowRenders.Renders

    @Test func candidates() async throws {
        let output = try #require(renderFolder)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var final: NSImage?
        try await WindowRenders().withSampleBook { store, book, preferences in
            let renders = try await WindowRenders.render(
                BookWindow(book: book, store: store, preferences: preferences, mode: .constant(.page)))
            try WindowRenders.png(renders.single).write(to: output.appending(path: "final-window@1x.png"))
            final = NSImage(data: try WindowRenders.png(renders.single))
        }
        let current = try #require(final)

        func write(_ renders: Renders, _ name: String, _ caption: String) throws {
            try WindowRenders.png(renders.single).write(to: output.appending(path: "\(name)@1x.png"))
            try WindowRenders.png(renders.double).write(to: output.appending(path: "\(name)@2x.png"))
            try WindowRenders.png(
                try WindowRenders.composite(
                    renders.single, caption: caption, beside: current, "Now: final window")
            )
            .write(to: output.appending(path: "\(name)-vs-final.png"))
        }

        func window(
            _ store: AppBookStore, _ book: AppOpenBook, _ preferences: AppPreferences, _ look: ErrorsLook
        )
            async throws -> Renders
        {
            try await WindowRenders.render(
                BookWindow(book: book, store: store, preferences: preferences, mode: .constant(.page))
                    .environment(\.errorsLook, look))
        }

        // c. The banner, while the damaged book is read-only.
        try await withBook(Self.damagedText()) { store, book, preferences in
            guard case .readOnly(.repairedOnOpen) = book.status else {
                Issue.record("precondition: the damaged book opens repaired and read-only")
                return
            }
            for (style, name, caption) in [
                (
                    BannerStyle.yellowStrip, "c1-banner-yellow-strip",
                    "c1 Banner: yellow strip across the window"
                ),
                (.infoBar, "c2-banner-info-bar", "c2 Banner: neutral info bar across the window"),
                (.inline, "c3-banner-inline", "c3 Banner: inline, above the Title strip"),
            ] {
                try write(
                    try await window(store, book, preferences, ErrorsLook(banner: style)), name,
                    caption + " (repaired)")
            }
            preferences.showRightPanelTab(.errors)
            try write(
                try await window(store, book, preferences, ErrorsLook()), "c4-read-only-errors-tab",
                "c4 Read-only: Errors tab after Show Repairs (view only)")
            preferences.showRightPanelTab(.comments)
        }
        try await withBook(Self.newerText()) { store, book, preferences in
            guard case .readOnly(.newerFormat) = book.status else {
                Issue.record("precondition: a format 3 book opens read-only")
                return
            }
            for (style, name, caption) in [
                (BannerStyle.yellowStrip, "c5-newer-yellow-strip", "c5 Newer format: yellow strip"),
                (.infoBar, "c6-newer-info-bar", "c6 Newer format: info bar"),
                (.inline, "c7-newer-inline", "c7 Newer format: inline"),
            ] {
                try write(
                    try await window(store, book, preferences, ErrorsLook(banner: style)), name, caption)
            }
        }

        // a and b, once the damaged book is editable.
        try await withBook(Self.damagedText()) { store, book, preferences in
            #expect(await store.makeEditable() == .editable)
            try #require(book.book.errorCount > 0)
            preferences.showRightPanelTab(.errors)
            try write(
                try await window(store, book, preferences, ErrorsLook(tabVisibility: .always)),
                "a1-tab-always-with-entries", "a1 Errors tab always shown: a book with entries")
            try write(
                try await window(store, book, preferences, ErrorsLook(tabVisibility: .whenPresent)),
                "a2-tab-when-present-with-entries", "a2 Errors tab only when present, with a count")
            for (style, name, caption) in [
                (ErrorRowStyle.cards, "b1-rows-cards", "b1 Rows: cards with an action row"),
                (.compact, "b2-rows-compact", "b2 Rows: compact list, actions in a ⋯ menu"),
                (.disclosure, "b3-rows-disclosure", "b3 Rows: disclosure for the line and actions"),
            ] {
                try write(try await window(store, book, preferences, ErrorsLook(rows: style)), name, caption)
            }
            let first = try #require(
                book.book.errorGroups.flatMap(\.refs).first { $0.entry.tag == .comments })
            try write(
                try await WindowRenders.render(
                    BookWindow(book: book, store: store, preferences: preferences, mode: .constant(.page))
                        .environment(\.errorsLook, ErrorsLook())
                        .environment(\.errorsEditing, first)),
                "b4-rows-cards-fixing", "b4 Rows: cards, fixing a comment's line")
        }
        try await WindowRenders().withSampleBook { store, book, preferences in
            preferences.showRightPanelTab(.errors)
            try write(
                try await window(store, book, preferences, ErrorsLook(tabVisibility: .always)),
                "a3-tab-always-no-entries", "a3 Errors tab always shown: a book with none")
            try write(
                try await window(store, book, preferences, ErrorsLook(tabVisibility: .whenPresent)),
                "a4-tab-when-present-no-entries", "a4 Errors tab only when present: a book with none")
            preferences.showRightPanelTab(.comments)
        }
    }

    // MARK: Books

    private func withBook(
        _ text: Data, _ body: (AppBookStore, AppOpenBook, AppPreferences) async throws -> Void
    ) async throws {
        try await withTemporaryFolder { folder in
            let books = BookController(role: .testHost)
            let store = books.store
            let url = folder.appending(path: "My Novel.sceneit", directoryHint: .isDirectory)
            #expect(await store.create(at: url) == .created)
            #expect(await store.closeBook() == .left)
            try text.write(to: url.appending(path: "book.md"), options: .atomic)
            _ = await store.open(url)
            let book = try #require(store.current)
            try await body(store, book, books.preferences)
            #expect(await store.closeBook() == .left)
        }
    }

    /// The sample book as a sync tool and a hand edit might leave it (book format §9.2's kinds of
    /// damage).
    static func damagedText() throws -> Data {
        var text = String(decoding: BookFormat.serialize(WindowRenders.sampleBook()), as: UTF8.self)
        func replace(_ old: String, _ new: String) throws {
            let range = try #require(text.range(of: old))
            text.replaceSubrange(range, with: new)
        }
        try replace("format: 2\n---\n", "format: 2\ncolour: blue\n---\n\nRemember to back this up!\n")
        try replace("behind her.", "behind her. \u{1F30A}")
        try replace(
            "already ashore.\n",
            "already ashore.\n\n### Comments\n"
                + "- c1 | mauve | 2026-10-31T20:40:00-07:00 | c45-58 | \"harbor lights\" | Too pretty?\n"
                + "- c3 | blue | 2026-10-31T20:41:00-07:00 | c4-9 | \"ferry left\" | Wrong range.\n")
        let arrival = try #require(text.range(of: "## Arrival\n"))
        let idLine = try #require(
            text.range(
                of: #"id: [^\n]+\n"#, options: .regularExpression, range: arrival.upperBound..<text.endIndex))
        text.removeSubrange(idLine)
        let letter = try #require(text.range(of: "## The letter\n"))
        let modified = try #require(
            text.range(
                of: #"modified: [^\n]+\n"#, options: .regularExpression,
                range: letter.upperBound..<text.endIndex))
        text.insert(contentsOf: "mood: grim\n", at: modified.upperBound)
        return Data(text.utf8)
    }

    static func newerText() -> Data {
        let text = String(decoding: BookFormat.serialize(WindowRenders.sampleBook()), as: UTF8.self)
        return Data(text.replacingOccurrences(of: "format: 2\n", with: "format: 3\n").utf8)
    }
}
