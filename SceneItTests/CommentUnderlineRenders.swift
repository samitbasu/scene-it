import AppKit
import SceneItCore
import SwiftUI
import Testing

@testable import SceneIt

/// Comment underlines (#24, ADR 0032) as the owner chose them, on the page at 100%: the
/// mockup's demo text with one comment, two and three overlapping, one across a line wrap, one
/// over highlighted text and one inside a selection, then all seven palette colors and a stack
/// deeper than fits; and in the notes, where overlapping comments have the fallback.
extension WindowRenders {
    @Test func commentUnderlines() async throws {
        let output = try #require(renderFolder)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let (book, selection) = Self.underlinedBook()
        try await withSampleBook(book) { store, book, preferences in
            // A window of its own for each render: one `BookWindow` keeps its editors.
            let window = {
                BookWindow(
                    book: book, store: store, preferences: preferences,
                    formatting: EditorFormatting(preferences: preferences), mode: .constant(.page))
            }
            try Self.write(
                try await Self.render(window()) { window in
                    let page = try #require(Self.page(in: window))
                    try #require(
                        page.commentPalette != .empty, "precondition: the scene's comments reached the page")
                    page.setSelectedRange(selection)
                },
                name: "underlines",
                caption: "Comment underlines: 1 pt, 1.5 pt apart, 3 pt below the baseline",
                to: output)
            preferences.showRightPanelTab(.notes)
            defer { preferences.showRightPanelTab(.comments) }
            try Self.write(
                try await Self.render(window()) { window in
                    let notes = try #require(
                        subviewTree(of: window.contentView).compactMap { $0 as? SceneTextView }
                            .first { !($0 is ManuscriptTextView) })
                    try #require(!notes.string.isEmpty, "precondition: the notes are shown")
                },
                name: "underlines-notes",
                caption: "In the notes, overlapping comments get one line in the newest color", to: output)
        }
    }

    /// The sample book with the mockup's first scene commented, and the range to select in it.
    static func underlinedBook() -> (Book, NSRange) {
        var book = sampleBook()
        let created = Timestamp(.now, in: .current)
        book.scenes[0].comments = []
        func comment(_ color: PaletteColor) -> CommentID {
            let id = CommentID(rawValue: "c\(book.scenes[0].comments.count + 1)")
            book.scenes[0].comments.append(
                Comment(id: id, color: color, text: "A \(color.rawValue) comment", created: created))
            return id
        }
        let ferry = comment(.red)
        let asleep = comment(.blue)
        let packed = comment(.purple)
        let dark = comment(.green)
        let theDark = comment(.pink)
        let girl = comment(.red)
        let deckhand = comment(.blue)
        let swore = comment(.green)
        let letter = comment(.purple)
        let palette = PaletteColor.allCases.map { ($0, comment($0)) }
        let deep = [PaletteColor.red, .blue, .green, .purple, .pink, .gray].map(comment)
        let notesOlder = comment(.green)
        let notesNewer = comment(.pink)
        let notesLetter = comment(.blue)

        let selected = "He found the letter under the bench"
        let body: [Paragraph] = [
            [
                Run("The ferry left at dawn", comments: [ferry]),
                Run(", and Mara watched the harbor lights go out one by one behind her."),
            ],
            [
                Run("She had "), Run("packed ", comments: [packed]), Run("in ", comments: [packed, dark]),
                Run("the dark", comments: [packed, dark, theDark]), Run(", by", comments: [packed, theDark]),
                Run(" feel", comments: [packed]), Run(", the way she used to "),
                Run("as a girl", highlight: .green, comments: [girl]),
                Run(" when "), Run("the house was asleep", comments: [asleep]),
                Run(" and leaving still seemed like a game."),
            ],
            [
                Run("Halfway across, the engine coughed and the "), Run("deckhand ", comments: [deckhand]),
                Run("swore at it", comments: [deckhand, swore]), Run(" in a language", comments: [swore]),
                Run(" she half remembered. He found the "), Run("letter", comments: [letter]),
                Run(" under the bench an hour later, but by then she was already ashore."),
            ],
            Paragraph(
                [Run("Seven colors: ")]
                    + palette.flatMap { color, id in
                        [Run(color.rawValue, comments: [id]), Run(color == .pink ? "." : ", ")]
                    }),
            Paragraph(
                [Run("Six comments, each a word later: ")]
                    + ["one", "two", "three", "four", "five", "six"].enumerated().map { index, word in
                        Run(word + (index < 5 ? " " : ""), comments: Set(deep.prefix(index + 1)))
                    } + [Run(".")]),
        ]
        book.scenes[0].body = body
        book.scenes[0].notes = [
            [
                Run("Check the tide tables: would a ferry "),
                Run("really leave", comments: [notesOlder]),
                Run(" at dawn", comments: [notesOlder, notesNewer]),
                Run(" in March?", comments: [notesNewer]),
            ],
            [
                Run("Who kept the mother's "), Run("letter", comments: [notesLetter]),
                Run(" all these years?"),
            ],
        ]
        let text = body.map(\.text).joined(separator: "\n") as NSString
        return (book, text.range(of: selected))
    }
}
