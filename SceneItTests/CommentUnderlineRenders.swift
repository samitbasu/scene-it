import AppKit
import SceneItCore
import SwiftUI
import Testing

@testable import SceneIt

/// Comment underlines (#24, ADR 0032) on the page at 100%, in each candidate style for the
/// owner's pick: the mockup's demo text with one comment, two and three overlapping, one across
/// a line wrap, one over highlighted text and one inside a selection, then all seven palette
/// colors and a stack deeper than fits.
extension WindowRenders {
    static let underlineCandidates: [(name: String, caption: String, style: UnderlineStyle)] = [
        ("thin", "A: 1 pt lines, 2 pt apart, 3 pt below the baseline", .thin),
        ("medium", "B: 1.5 pt lines, 2 pt apart, 3 pt below the baseline", .medium),
        ("thick", "C: 2 pt lines, 2 pt apart, 3 pt below the baseline", .thick),
        ("medium-tight", "D: 1.5 pt lines, 1 pt apart, 3 pt below the baseline", .mediumTight),
        ("medium-high", "E: 1.5 pt lines, 2 pt apart, 1.5 pt below the baseline", .mediumHigh),
        ("thin-tight", "F: 1 pt lines, 1.5 pt apart, 3 pt below the baseline", .thinTight),
        ("hairline", "G: hairlines (one pixel), 1.5 pt apart, 3 pt below the baseline", .hairline),
    ]

    /// The second round (the owner asked for thinner lines): these, on a sheet of their own.
    static let secondRound: Set = ["thin", "medium", "thin-tight", "hairline"]

    @Test func commentUnderlines() async throws {
        let output = try #require(renderFolder)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let (book, selection) = Self.underlinedBook()
        try await withSampleBook(book) { store, book, preferences in
            let window = BookWindow(
                book: book, store: store, preferences: preferences,
                formatting: EditorFormatting(preferences: preferences), mode: .constant(.page))
            var crops: [(caption: String, single: CGImage, double: CGImage)] = []
            for candidate in Self.underlineCandidates {
                var pageCrop = CGRect.zero
                let renders = try await Self.render(window) { window in
                    let page = try #require(Self.page(in: window))
                    try #require(
                        page.commentPalette != .empty, "precondition: the scene's comments reached the page")
                    page.underlineStyle = candidate.style
                    page.setSelectedRange(selection)
                    pageCrop = Self.pageTop(of: page, in: window)
                }
                try Self.write(
                    renders, name: "underlines-\(candidate.name)", caption: candidate.caption, to: output)
                crops.append(
                    (
                        candidate.caption, try Self.crop(renders.single, to: pageCrop, scale: 1),
                        try Self.crop(renders.double, to: pageCrop, scale: 2)
                    ))
            }
            let second = crops.filter { crop in
                Self.underlineCandidates.contains {
                    Self.secondRound.contains($0.name) && $0.caption == crop.caption
                }
            }
            for scale in [1, 2] {
                try Self.png(try Self.sideBySide(crops, scale: scale))
                    .write(to: output.appending(path: "underlines-compare@\(scale)x.png"))
                try Self.png(try Self.sideBySide(second, scale: scale))
                    .write(to: output.appending(path: "underlines-compare-2@\(scale)x.png"))
            }
        }
    }

    /// The page's text, below its top margin, in the frame view's coordinates.
    private static func pageTop(of page: ManuscriptTextView, in window: NSWindow) -> CGRect {
        let visible = page.pageRect.intersection(page.visibleRect)
        let top = NSRect(x: visible.minX, y: visible.minY + 56, width: visible.width, height: 300)
        return page.convert(top, to: window.contentView?.superview)
    }

    /// `rect`, in the unflipped frame view's points, cut out of a render at `scale`.
    private static func crop(_ rep: NSBitmapImageRep, to rect: CGRect, scale: Int) throws -> CGImage {
        let image = try #require(rep.cgImage)
        let s = CGFloat(scale)
        let pixels = CGRect(
            x: rect.minX * s, y: (windowSize.height - rect.maxY) * s, width: rect.width * s,
            height: rect.height * s)
        return try #require(image.cropping(to: pixels.integral))
    }

    /// The candidates' crops one above another, each under its caption, at `scale`.
    private static func sideBySide(_ crops: [(caption: String, single: CGImage, double: CGImage)], scale: Int)
        throws -> NSBitmapImageRep
    {
        let images = crops.map { scale == 1 ? $0.single : $0.double }
        let s = CGFloat(scale)
        let gap: CGFloat = 24
        let header: CGFloat = 36
        let cell = CGSize(
            width: CGFloat(images.map(\.width).max() ?? 0) / s,
            height: CGFloat(images.map(\.height).max() ?? 0) / s)
        let size = CGSize(
            width: cell.width + 2 * gap, height: CGFloat(images.count) * (cell.height + header) + gap)
        let rep = blankBitmap(width: Int(size.width * s), height: Int(size.height * s))
        rep.size = size
        let context = try #require(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor(white: 0.8, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium)
        ]
        for (index, (crop, image)) in zip(crops, images).enumerated() {
            let top = size.height - CGFloat(index) * (cell.height + header)
            NSAttributedString(string: crop.caption, attributes: attributes)
                .draw(at: NSPoint(x: gap, y: top - header + 10))
            let height = CGFloat(image.height) / s
            context.cgContext.draw(
                image,
                in: CGRect(x: gap, y: top - header - height, width: CGFloat(image.width) / s, height: height))
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep
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
        let text = body.map(\.text).joined(separator: "\n") as NSString
        return (book, text.range(of: selected))
    }
}
