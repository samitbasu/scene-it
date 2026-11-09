import AppKit
import PDFKit
import SceneItCore
import SwiftUI
import Testing

@testable import SceneIt

/// Print (#35), for the owner to judge beside mockup 15: the pages as the print operation saves
/// them to PDF (text only, portrait; text with comments, landscape, with crowded comments pushed
/// down), drawn at 2×; and the print dialog's accessory, alone, since the system dialog around it
/// can't be drawn offscreen.
extension WindowRenders {
    static let printMockup = "15-print-dialog.png"

    @Test func print() async throws {
        let output = try #require(renderFolder).appending(path: "print", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let book = Self.printSample()
        for (layout, name) in [(PrintLayout.textOnly, "portrait"), (.withComments, "landscape")] {
            let view = PrintTests.view(book, layout: layout)
            let document = try PrintTests.pdf(view, PrintTests.printInfo(layout))
            for index in 0..<min(document.pageCount, 2) {
                let page = try #require(document.page(at: index))
                let rep = try Self.bitmap(of: page, scale: 2)
                try Self.png(rep).write(to: output.appending(path: "\(name)-page-\(index + 1)@2x.png"))
                try Self.png(try Self.side(by: rep, caption: "Print: \(name), page \(index + 1)"))
                    .write(to: output.appending(path: "\(name)-page-\(index + 1)-vs-mockup.png"))
            }
        }
        let choices = PrintChoices(openScene: book.scenes.first?.id, in: book)
        for layout in PrintLayout.allCases {
            choices.layout = layout
            let view = PrintAccessoryView(choices: choices).background(Color(nsColor: .windowBackgroundColor))
            let name = layout == .textOnly ? "accessory-text-only" : "accessory-with-comments"
            let rep = try await Self.withHostedView(view) { Self.bitmap(of: $0, scale: 2) }
            try Self.png(rep).write(to: output.appending(path: "\(name)@2x.png"))
            try Self.png(try Self.side(by: rep, caption: "The print dialog's accessory"))
                .write(to: output.appending(path: "\(name)-vs-mockup.png"))
        }
    }

    /// The mockup's ferry scene, long enough for two pages, with comments crowded on a few lines.
    static func printSample() -> Book {
        let modified = Timestamp("2026-11-03T10:15:00-08:00")!
        func comment(_ number: Int, _ color: PaletteColor, _ text: String) -> SceneItCore::Comment {
            SceneItCore::Comment(
                id: CommentID(rawValue: "01JC4K0000000000000000C0\(String(format: "%02d", number))"),
                color: color,
                text: text, created: Timestamp("2026-11-03T10:\(String(format: "%02d", number)):00-08:00")!)
        }
        let reveal = comment(1, .purple, "Too early for this reveal?")
        let schedule = comment(2, .red, "Check the ferry schedule for the 1950s.")
        let girl = comment(3, .blue, "How old was she when she left? Keep this consistent with chapter 3.")
        let game = comment(4, .green, "Echo this in the last scene.")
        let swore = comment(5, .gray, "Which language? Decide before the market scene.")
        let ashore = comment(6, .pink, "Too neat. Let her see the letter go over the side instead?")
        let paragraphs: [Paragraph] = [
            [
                Run("The ferry left at dawn", comments: [schedule.id]),
                Run(", and Mara watched the harbor lights go out one by one behind her."),
            ],
            [
                Run("She had packed in the dark, by feel, the way she used to as a "),
                Run("girl", comments: [girl.id]),
                Run(" when the house was asleep and leaving still seemed like a "),
                Run("game", styles: [.italic], comments: [game.id]), Run("."),
            ],
            [
                Run("Halfway across, the engine coughed and the deckhand "),
                Run("swore", comments: [swore.id]),
                Run(" at it in a language she half remembered. He found the "),
                Run("letter", color: .purple, comments: [reveal.id]),
                Run(" under the bench an hour later, but by then she was "),
                Run("already ashore", highlight: .green, comments: [ashore.id]), Run("."),
            ],
        ]
        let filler: [Paragraph] = [
            [
                Run(
                    "Nobody met her at the landing, which she had half expected and wholly dreaded. \"Well,\" she said "
                        + "to nobody -- and then, to the gulls, \"well...\"")
            ],
            [
                Run("The radio crackled twice and then gave up entirely, and the fog came in behind it, "),
                Run("thick as wool", styles: [.bold]), Run(", until the far shore was only a rumour."),
            ],
        ]
        let ferry = BookScene(
            id: SceneID(rawValue: "ferry"), modified: modified, title: "The ferry",
            body: paragraphs + Array(repeating: filler, count: 9).flatMap(\.self),
            comments: [reveal, schedule, girl, game, swore, ashore])
        return Book(title: "My Novel", scenes: [ferry])
    }

    /// `page` drawn white at `scale` pixels a point, with a hairline round the sheet.
    static func bitmap(of page: PDFPage, scale: Int) throws -> NSBitmapImageRep {
        let bounds = page.bounds(for: .mediaBox)
        let rep = blankBitmap(width: Int(bounds.width) * scale, height: Int(bounds.height) * scale)
        rep.size = bounds.size
        let context = try #require(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        NSColor.white.setFill()
        NSRect(origin: .zero, size: bounds.size).fill()
        page.draw(with: .mediaBox, to: context.cgContext)
        NSColor(white: 0.6, alpha: 1).setStroke()
        NSRect(origin: .zero, size: bounds.size).insetBy(dx: 0.25, dy: 0.25).frame(withWidth: 0.5)
        return rep
    }

    /// `render` at half its pixels on the left and the mockup on the right, each under a caption,
    /// at the same height.
    static func side(by render: NSBitmapImageRep, caption: String) throws -> NSBitmapImageRep {
        let mockup = try #require(NSImage(contentsOf: mockup(printMockup)))
        let height: CGFloat = 900
        let renderSize = CGSize(
            width: render.size.width * height / render.size.height, height: height)
        let renderBox = render.size.height < height ? render.size : renderSize
        let mockupSize = CGSize(width: mockup.size.width * height / mockup.size.height, height: height)
        let (gap, header): (CGFloat, CGFloat) = (24, 40)
        let size = CGSize(width: renderBox.width + gap + mockupSize.width, height: height + header)
        let rep = blankBitmap(width: Int(size.width), height: Int(size.height))
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
        NSAttributedString(string: caption, attributes: attributes).draw(
            at: NSPoint(x: 8, y: size.height - 30))
        NSAttributedString(string: "Mockup: \(printMockup)", attributes: attributes)
            .draw(at: NSPoint(x: renderBox.width + gap + 8, y: size.height - 30))
        render.draw(in: NSRect(origin: NSPoint(x: 0, y: height - renderBox.height), size: renderBox))
        mockup.draw(in: NSRect(origin: NSPoint(x: renderBox.width + gap, y: 0), size: mockupSize))
        return rep
    }
}
