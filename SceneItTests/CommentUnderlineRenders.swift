import AppKit
import SceneItCore
import SwiftUI
import Testing

@testable import SceneIt

/// Comment underlines (#24, ADR 0032) as the owner chose them, on the page at 100%: the
/// mockup's demo text with one comment, two and three overlapping, one across a line wrap, one
/// over highlighted text and one inside a selection, all seven palette colors, a stack deeper
/// than fits, a misspelled commented word, and a comment in two pieces.
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
            let page = try await Self.render(window()) { window in
                let page = try #require(Self.page(in: window))
                try #require(
                    page.commentPalette != .empty, "precondition: the scene's comments reached the page")
                page.setSelectedRange(selection)
            }
            try Self.write(
                page, name: "underlines",
                caption: "Comment underlines: 1 pt, 1.5 pt apart, 3 pt below the baseline",
                to: output)
            try Self.png(Self.closeUp(page.double, CGRect(x: 360, y: 240, width: 500, height: 330)))
                .write(to: output.appending(path: "underlines-close-up@2x.png"))
        }
    }

    /// `rect`, in the window's top-left points, cut from a 2x render.
    static func closeUp(_ rep: NSBitmapImageRep, _ rect: CGRect) throws -> NSBitmapImageRep {
        let image = try #require(rep.cgImage)
        let pixels = CGRect(
            x: rect.minX * 2, y: rect.minY * 2, width: rect.width * 2, height: rect.height * 2)
        return NSBitmapImageRep(cgImage: try #require(image.cropping(to: pixels)))
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
        let misspelled = comment(.blue)
        let pieces = comment(.red)
        let between = comment(.green)

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
            [
                Run("Pieter had "), Run("paintd", comments: [misspelled]),
                Run(" the boat the same blue as the house."),
            ],
            [
                Run("Nobody", comments: [pieces]), Run(" met her at the "),
                Run("landing", comments: [between]),
                Run(", which she had half expected and wholly "), Run("dreaded", comments: [pieces]),
                Run("."),
            ],
        ]
        book.scenes[0].body = body
        let text = body.map(\.text).joined(separator: "\n") as NSString
        return (book, text.range(of: selected))
    }
}
