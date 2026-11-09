import AppKit
import SceneItCore
import SceneItTestSupport
import Testing
import WebKit

@testable import SceneIt

/// Copy Review's and Save Review…'s look (#81), chosen by default while the owner was away, into a
/// `review-output/` subfolder, each drawn by WebKit offscreen from the worked example (review
/// format §8): the spec's look (A, shipped) and two alternatives, B (sans-serif, each comment in a
/// tinted box) and C (Georgia, the passage underlined, the comment in blue ink). For each, the
/// standalone page with one item ticked (`page-<x>`) and the clipboard HTML as pasted into a
/// message (`email-<x>`), at 2×, and all three pages side by side (`compare-pages`).
@MainActor
@Suite(.serialized, .enabled(if: renderFolder != nil), .timeLimit(.minutes(2)))
struct ReviewOutputRenders {
    static let candidates: [(name: String, caption: String, look: ReviewLook)] = [
        ("a-spec", "A (shipped): the spec's look, Georgia, passage on yellow", .standard),
        ("b-sans-boxed", "B: sans-serif, each comment in a tinted box", sansBoxed),
        ("c-underlined", "C: Georgia, passage underlined, comment in blue ink", underlined),
    ]

    @Test func reviewOutputRenders() async throws {
        let output = try #require(renderFolder).appending(path: "review-output", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let (report, id) = try ReviewOutputFixture.report()
        var pages: [(String, NSImage)] = []
        for candidate in Self.candidates {
            let page = ReviewPage(size: CGSize(width: 900, height: 600))
            try await page.load(ReviewHTML.page(report, review: id, look: candidate.look))
            _ = try await page.string(
                "document.querySelector('input[data-item=\"s1/c2\"]').click(); ''")
            let image = try await Self.snapshot(page)
            try Self.png(image).write(to: output.appending(path: "page-\(candidate.name)@2x.png"))
            pages.append((candidate.caption, image))

            let email = ReviewPage(size: CGSize(width: 680, height: 600))
            try await email.load(Self.message(ReviewHTML.clipboard(report, look: candidate.look)))
            try Self.png(try await Self.snapshot(email)).write(
                to: output.appending(path: "email-\(candidate.name)@2x.png"))
        }
        try Self.png(try Self.sideBySide(pages)).write(to: output.appending(path: "compare-pages.png"))
    }

    /// The clipboard HTML in a plain white message body, as a mail client shows a paste.
    static func message(_ fragment: String) -> String {
        "<!DOCTYPE html><html><head><meta charset=\"utf-8\"></head>"
            + "<body style=\"margin:0;padding:24px;background-color:#FFFFFF;\">\(fragment)</body></html>"
    }

    /// The whole page at 2×, its window grown to the page's height first.
    static func snapshot(_ page: ReviewPage) async throws -> NSImage {
        let height = try #require(try await page.number("document.documentElement.scrollHeight"))
        let size = CGSize(width: page.view.frame.width, height: CGFloat(height))
        page.window.setContentSize(size)
        page.view.frame = NSRect(origin: .zero, size: size)
        try await Task.sleep(for: .milliseconds(300))
        let configuration = WKSnapshotConfiguration()
        configuration.rect = NSRect(origin: .zero, size: size)
        configuration.snapshotWidth = NSNumber(value: Double(size.width * 2))
        return try await page.view.takeSnapshot(configuration: configuration)
    }

    static func png(_ image: NSImage) throws -> Data {
        let rep = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    /// The images in a row, each under its caption, at their 1× size.
    static func sideBySide(_ images: [(String, NSImage)]) throws -> NSImage {
        let gap: CGFloat = 24
        let header: CGFloat = 40
        let width = images.map(\.1.size.width).reduce(0, +) + gap * CGFloat(images.count + 1)
        let height = (images.map(\.1.size.height).max() ?? 0) + header + gap
        let composite = NSImage(size: CGSize(width: width, height: height), flipped: false) { bounds in
            NSColor(white: 0.8, alpha: 1).setFill()
            bounds.fill()
            var x = gap
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 16, weight: .medium)
            ]
            for (caption, image) in images {
                caption.draw(at: NSPoint(x: x, y: height - header + 10), withAttributes: attributes)
                image.draw(
                    in: NSRect(
                        x: x, y: height - header - image.size.height, width: image.size.width,
                        height: image.size.height))
                x += image.size.width + gap
            }
            return true
        }
        return composite
    }

    static let sansBoxed = ReviewLook(
        report:
            "font-family:-apple-system,Helvetica,Arial,sans-serif;font-size:15px;line-height:1.5;color:#1D1D1F;",
        title: "margin:0 0 4px 0;font-size:22px;font-weight:bold;",
        date: "margin:0 0 24px 0;color:#6E6E73;",
        generalNotesHeading: "margin:0 0 8px 0;font-size:17px;font-weight:bold;",
        sceneHeading: "margin:24px 0 8px 0;font-size:17px;font-weight:bold;",
        item: "margin:0 0 16px 0;",
        quote: "margin:0;",
        context: "color:#6E6E73;",
        passage: "background-color:#FFF2A8;",
        comment:
            "margin:6px 0 0 28px;padding:6px 10px;background-color:#F2F4F7;border-left:3px solid #8AA4C8;",
        notesHeading: "margin:16px 0 4px 0;font-weight:bold;",
        paragraph: "margin:0 0 8px 0;",
        checkbox: "margin:0 8px 0 0;",
        page: "margin:0;padding:32px;background-color:#FFFFFF;",
        column: "max-width:40em;margin:0 auto;",
        pageNotice:
            "margin:0 0 16px 0;padding:8px 12px;background-color:#F2F2F2;font-family:-apple-system,sans-serif;"
    )

    static let underlined = ReviewLook(
        report: "font-family:Georgia,serif;font-size:16px;line-height:1.5;color:#222222;",
        title: "margin:0 0 4px 0;font-size:22px;font-weight:bold;",
        date: "margin:0 0 24px 0;color:#777777;",
        generalNotesHeading: "margin:0 0 8px 0;font-size:18px;font-weight:bold;",
        sceneHeading: "margin:24px 0 8px 0;font-size:18px;font-weight:bold;",
        item: "margin:0 0 16px 0;",
        quote: "margin:0;",
        context: "color:#8A8A8A;",
        passage: "border-bottom:2px solid #E0A800;",
        comment: "margin:4px 0 0 28px;color:#1F4E79;",
        notesHeading: "margin:16px 0 4px 0;font-weight:bold;",
        paragraph: "margin:0 0 8px 0;",
        checkbox: "margin:0 8px 0 0;",
        page: "margin:0;padding:32px;background-color:#FFFFFF;",
        column: "max-width:40em;margin:0 auto;",
        pageNotice: "margin:0 0 16px 0;padding:8px 12px;background-color:#F2F2F2;font-family:Georgia,serif;")
}

/// File → Copy Review and Save Review… with a review open, as the menu draws it.
extension BookStoreIntegrationTests {
    @Test(.enabled(if: renderFolder != nil)) func reviewOutputMenuRenders() async throws {
        let output = try #require(renderFolder).appending(path: "review-output", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try await withTemporaryFolder { folder in
            let books = BookController.shared
            try #require(books.store.isChoosing, "precondition: the start screen")
            let copy = folder.appending(path: "My Novel.md")
            try Data(ReviewOutputFixture.copy.utf8).write(to: copy)
            #expect(await books.store.openReview(copy) == .opened)
            try ReviewOutputFixture.comment(try #require(books.store.current))
            await eventually { Self.copyReviewIsEnabled() == true }
            try OneBookRenders.write(OneBookRenders.fileMenu(), name: "menu-copy-and-save-review", to: output)
            #expect(await books.store.closeBook() == .left)
        }
    }
}
